//
//  gravitylite.m
//  RemoteCall-only core port of Julio Verne's Gravity tweak.
//

#import "gravitylite.h"
#import "remote_objc.h"
#import "sb_walk.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <pthread.h>

typedef struct {
    double a;
    double b;
    double c;
    double d;
    double tx;
    double ty;
} GL_CGAffineTransform;

typedef struct {
    double x;
    double y;
    double w;
    double h;
} GL_CGRect;

// Gravity behavior cache. 16 slots: home page (1) + dock (1) is the
// common case, extra headroom covers multi-page captures and future
// expansion. Overflow is logged, not silently dropped.
#define GRAVITY_MAX_BEHAVIORS 16
static uint64_t s_gravity_ptrs[GRAVITY_MAX_BEHAVIORS];
static volatile int s_gravity_ptr_count = 0;

static GravityLiteConfig s_gravity_last_config;
static volatile int s_gravity_last_config_valid = 0;
static volatile int s_gravity_active = 0;
static bool gravitylite_finish_apply(GravityLiteConfig config);

// Recovery poller: periodically pulls fully off-screen icons back to
// their recorded grid frames. Runs on its own thread.
//
// Gravity-angle updates come from SettingsViewController's motion handler
// (settings_start_gravity_motion), which also owns the lock/blank notify
// observers, so this file no longer keeps a CMMotionManager, a tilt thread,
// or its own display-state tokens.
static volatile int s_poller_running = 0;
static volatile int s_poller_exited = 0;
static pthread_t s_poller_thread;
static volatile int s_poller_thread_valid = 0;
// Serializes start/stop so the background join issued by
// gravitylite_stop_in_session() can never race with pthread_create().
static pthread_mutex_t s_poller_lifecycle_mutex = PTHREAD_MUTEX_INITIALIZER;
static void gl_poller_start(void);
static void gl_poller_stop(void);
static void gl_poller_stop_locked(void);
static void *gl_poller_thread_main(void *arg);

static pthread_mutex_t s_gravity_refresh_mutex = PTHREAD_MUTEX_INITIALIZER;
static volatile int s_gravity_last_logged_count = -1;

// (3) Recover on demand.
static volatile int s_recover_needed = 1;

// Cached NSString keys. These are intentionally never released: they live
// for the whole process lifetime, are reused across every dict/group
// creation, and releasing them would require tracking refcounts across
// RemoteCall boundaries for no benefit.
static uint64_t s_key_state = 0;
static uint64_t s_key_groups = 0;
static uint64_t s_key_animator = 0;
static uint64_t s_key_icons = 0;
static uint64_t s_key_listView = 0;
static uint64_t s_key_liveFrames = 0;

static void gl_keys_init(void);

// Forward declarations.
static int  gl_attach_behaviors(uint64_t animator, uint64_t items, GravityLiteConfig config);
static void gl_refresh_gravity_ptrs(void);
static void gl_recover_out_of_bounds_icons(void);
static int  gl_restore_group_to_grid(uint64_t group);
static uint64_t gl_current_root_list_view(uint64_t ctrl, uint64_t mgr);
static uint64_t gl_current_root_list_view_ios26_legacy(uint64_t ctrl);


static uint64_t gl_safe_msg(uint64_t obj, const char *selName,
                            uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!r_is_objc_ptr(obj) || !selName) return 0;
    if (!r_responds_main(obj, selName)) return 0;
    return r_msg2_main(obj, selName, a0, a1, a2, a3);
}

static uint64_t gl_icon_controller(void)
{
    uint64_t cls = r_class("SBIconController");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2(cls, "sharedInstance", 0, 0, 0, 0);
}

static uint64_t gl_icon_manager(uint64_t ctrl)
{
    return gl_safe_msg(ctrl, "iconManager", 0, 0, 0, 0);
}

static uint64_t gl_root_folder_controller(uint64_t ctrl, uint64_t mgr);

static uint64_t gl_dock_list_view(uint64_t ctrl, uint64_t mgr)
{
    uint64_t dock = gl_safe_msg(mgr, "dockListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(dock)) dock = gl_safe_msg(ctrl, "dockListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(dock)) {
        uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
        dock = gl_safe_msg(rootFC, "dockListView", 0, 0, 0, 0);
    }
    return dock;
}

static uint64_t gl_state_key(void)
{
    if (!r_is_objc_ptr(s_key_state)) {
        s_key_state = r_sel("cyanideGravityLiteState");
    }
    return s_key_state;
}

static void gl_keys_init(void)
{
    if (!r_is_objc_ptr(s_key_groups))     s_key_groups     = r_nsstr_retained("groups");
    if (!r_is_objc_ptr(s_key_animator))   s_key_animator   = r_nsstr_retained("animator");
    if (!r_is_objc_ptr(s_key_icons))      s_key_icons      = r_nsstr_retained("icons");
    if (!r_is_objc_ptr(s_key_listView))   s_key_listView   = r_nsstr_retained("listView");
    if (!r_is_objc_ptr(s_key_liveFrames)) s_key_liveFrames = r_nsstr_retained("liveFrames");
}

static uint64_t gl_get_state(uint64_t ctrl)
{
    uint64_t key = gl_state_key();
    if (!r_is_objc_ptr(ctrl) || !key) return 0;
    return r_dlsym_call(R_TIMEOUT, "objc_getAssociatedObject",
                        ctrl, key, 0, 0, 0, 0, 0, 0);
}

static void gl_set_state(uint64_t ctrl, uint64_t state)
{
    uint64_t key = gl_state_key();
    if (!r_is_objc_ptr(ctrl) || !key) return;
    r_dlsym_call(R_TIMEOUT, "objc_setAssociatedObject",
                 ctrl, key, state, state ? 1 : 0, 0, 0, 0, 0);
}

static uint64_t gl_new_remote(const char *className)
{
    uint64_t cls = r_class(className);
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2(cls, "new", 0, 0, 0, 0);
}

static void gl_release(uint64_t obj)
{
    if (r_is_objc_ptr(obj)) r_msg2(obj, "release", 0, 0, 0, 0);
}

static int gl_remote_ios_major(void)
{
    uint64_t uid = r_class("UIDevice");
    uint64_t device = r_is_objc_ptr(uid) ? r_msg2(uid, "currentDevice", 0, 0, 0, 0) : 0;
    uint64_t version = r_is_objc_ptr(device) ? gl_safe_msg(device, "systemVersion", 0, 0, 0, 0) : 0;
    char buf[32] = {0};
    if (!r_read_nsstring(version, buf, sizeof(buf))) return 0;
    int major = atoi(buf);
    return major > 0 ? major : 0;
}

static void gl_dict_set(uint64_t dict, uint64_t key, uint64_t value)
{
    if (!r_is_objc_ptr(dict) || !r_is_objc_ptr(value) || !r_is_objc_ptr(key)) return;
    r_msg2(dict, "setObject:forKey:", value, key, 0, 0);
}

static uint64_t gl_dict_get(uint64_t dict, uint64_t key)
{
    if (!r_is_objc_ptr(dict) || !r_is_objc_ptr(key)) return 0;
    return r_msg2(dict, "objectForKey:", key, 0, 0, 0);
}

static void gl_array_add(uint64_t array, uint64_t obj)
{
    if (!r_is_objc_ptr(array) || !r_is_objc_ptr(obj)) return;
    r_msg2(array, "addObject:", obj, 0, 0, 0);
}

static uint64_t gl_array_count(uint64_t array)
{
    if (!r_is_objc_ptr(array)) return 0;
    return r_msg2(array, "count", 0, 0, 0, 0);
}

static uint64_t gl_array_object(uint64_t array, uint64_t index)
{
    if (!r_is_objc_ptr(array)) return 0;
    return r_msg2(array, "objectAtIndex:", index, 0, 0, 0);
}

static bool gl_ptr_seen(uint64_t ptr, const uint64_t *items, int count)
{
    for (int i = 0; i < count; i++) {
        if (items[i] == ptr) return true;
    }
    return false;
}

static void gl_set_double(uint64_t obj, const char *selName, double value)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return;
    r_msg2_main_raw(obj, selName,
                    &value, sizeof(value),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void gl_set_bool(uint64_t obj, const char *selName, bool value)
{
    if (!r_is_objc_ptr(obj) || !r_responds_main(obj, selName)) return;
    uint8_t v = value ? 1 : 0;
    r_msg2_main_raw(obj, selName,
                    &v, sizeof(v),
                    NULL, 0, NULL, 0, NULL, 0);
}

static bool gl_get_rect(uint64_t obj, const char *selName, GL_CGRect *out)
{
    if (!r_is_objc_ptr(obj) || !selName || !out) return false;
    if (!r_responds_main(obj, selName)) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(obj, selName,
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static void gl_set_rect(uint64_t obj, const char *selName, GL_CGRect rect)
{
    if (!r_is_objc_ptr(obj) || !selName || !r_responds_main(obj, selName)) return;
    r_msg2_main_raw(obj, selName,
                    &rect, sizeof(rect),
                    NULL, 0, NULL, 0, NULL, 0);
}

static uint64_t gl_value_with_rect(GL_CGRect rect)
{
    uint64_t cls = r_class("NSValue");
    if (!r_is_objc_ptr(cls)) return 0;
    return r_msg2_main_raw(cls, "valueWithCGRect:",
                           &rect, sizeof(rect),
                           NULL, 0, NULL, 0, NULL, 0);
}

static bool gl_rect_from_value(uint64_t value, GL_CGRect *out)
{
    if (!r_is_objc_ptr(value) || !out) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(value, "CGRectValue",
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static bool gl_rect_valid(GL_CGRect rect)
{
    return rect.w > 1.0 && rect.h > 1.0;
}

static bool gl_view_is_hidden(uint64_t view)
{
    if (!r_is_objc_ptr(view)) return true;
    if (r_responds_main(view, "isHidden") && r_msg2_main(view, "isHidden", 0, 0, 0, 0)) return true;
    return false;
}

static void gl_reset_transform(uint64_t view)
{
    if (!r_is_objc_ptr(view) || !r_responds_main(view, "setTransform:")) return;
    GL_CGAffineTransform t = { 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
    r_msg2_main_raw(view, "setTransform:",
                    &t, sizeof(t),
                    NULL, 0, NULL, 0, NULL, 0);
}

static void gl_layout_list_view(uint64_t listView)
{
    if (!r_is_objc_ptr(listView)) return;

    if (r_responds_main(listView, "setIconsNeedLayout")) {
        r_msg2_main(listView, "setIconsNeedLayout", 0, 0, 0, 0);
    }
    if (r_responds_main(listView, "layoutIconsIfNeeded:domino:")) {
        double duration = 0.2;
        uint8_t no = 0;
        r_msg2_main_raw(listView, "layoutIconsIfNeeded:domino:",
                        &duration, sizeof(duration),
                        &no, sizeof(no),
                        NULL, 0, NULL, 0);
    } else {
        gl_safe_msg(listView, "setNeedsLayout", 0, 0, 0, 0);
        gl_safe_msg(listView, "layoutIfNeeded", 0, 0, 0, 0);
    }
}

static uint64_t gl_alloc_init_with_items(const char *className, uint64_t items)
{
    uint64_t cls = r_class(className);
    if (!r_is_objc_ptr(cls) || !r_is_objc_ptr(items)) return 0;
    uint64_t obj = r_msg2(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t inited = r_msg2_main(obj, "initWithItems:", items, 0, 0, 0);
    return r_is_objc_ptr(inited) ? inited : obj;
}

static uint64_t gl_animator_for_reference_view(uint64_t referenceView)
{
    uint64_t cls = r_class("UIDynamicAnimator");
    if (!r_is_objc_ptr(cls) || !r_is_objc_ptr(referenceView)) return 0;
    uint64_t obj = r_msg2(cls, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t inited = r_msg2_main(obj, "initWithReferenceView:", referenceView, 0, 0, 0);
    return r_is_objc_ptr(inited) ? inited : obj;
}

static int gl_attach_behaviors(uint64_t animator, uint64_t items, GravityLiteConfig config)
{
    if (!r_is_objc_ptr(animator) || !r_is_objc_ptr(items)) return 0;
    int attached = 0;

    // Collision: keeps icons inside the reference view bounds.
    uint64_t collision = gl_alloc_init_with_items("UICollisionBehavior", items);
    if (r_is_objc_ptr(collision)) {
        gl_set_bool(collision, "setTranslatesReferenceBoundsIntoBoundary:", true);
        if (r_responds_main(collision, "setCollisionMode:")) {
            r_msg2_main(collision, "setCollisionMode:", 3, 0, 0, 0);
        }
        r_msg2_main(animator, "addBehavior:", collision, 0, 0, 0);
        attached++;
        gl_release(collision);
    }

    // Item behavior: elasticity, friction, density, resistance, rotation.
    uint64_t itemBehavior = gl_alloc_init_with_items("UIDynamicItemBehavior", items);
    if (r_is_objc_ptr(itemBehavior)) {
        gl_set_double(itemBehavior, "setElasticity:", config.bounce);
        gl_set_double(itemBehavior, "setFriction:", config.friction);
        gl_set_double(itemBehavior, "setDensity:", 1.0);
        // (6) Minimum damping so icons eventually stop.
        double res = config.resistance;
        if (res < 0.05) res = 0.05;
        gl_set_double(itemBehavior, "setResistance:", res);
        gl_set_double(itemBehavior, "setAngularResistance:", config.angularResistance);
        gl_set_bool(itemBehavior, "setAllowsRotation:", config.allowsRotation);
        r_msg2_main(animator, "addBehavior:", itemBehavior, 0, 0, 0);
        attached++;
        gl_release(itemBehavior);
    }

    // Gravity: initial angle/magnitude, updated by the tilt thread.
    uint64_t gravity = gl_alloc_init_with_items("UIGravityBehavior", items);
    if (r_is_objc_ptr(gravity)) {
        gl_set_double(gravity, "setAngle:", M_PI_2);
        gl_set_double(gravity, "setMagnitude:", config.magnitude);
        r_msg2_main(animator, "addBehavior:", gravity, 0, 0, 0);
        attached++;
        gl_release(gravity);
    }

    return attached;
}

// Collect matching UIPushBehavior instances first, then remove them. This
// avoids mutating the live behaviors array while iterating it.
static void gl_remove_push_behaviors(uint64_t animator)
{
    if (!r_is_objc_ptr(animator)) return;
    uint64_t pushCls = r_class("UIPushBehavior");
    uint64_t behaviors = gl_safe_msg(animator, "behaviors", 0, 0, 0, 0);
    if (!r_is_objc_ptr(pushCls) || !r_is_objc_ptr(behaviors)) return;

    enum { PUSH_CAP = 128 };
    uint64_t matches[PUSH_CAP] = {0};
    int matchCount = 0;

    uint64_t count = gl_array_count(behaviors);
    if (count > 256) count = 256;
    for (uint64_t i = 0; i < count && matchCount < PUSH_CAP; i++) {
        uint64_t behavior = gl_array_object(behaviors, i);
        if (!r_is_objc_ptr(behavior)) continue;
        if (!r_msg2(behavior, "isKindOfClass:", pushCls, 0, 0, 0)) continue;
        matches[matchCount++] = behavior;
    }

    for (int i = 0; i < matchCount; i++) {
        r_msg2_main(animator, "removeBehavior:", matches[i], 0, 0, 0);
    }
}

static uint64_t gl_root_folder_controller(uint64_t ctrl, uint64_t mgr)
{
    uint64_t roots[] = { mgr, ctrl };
    const char *sels[] = {
        "rootFolderController",
        "_rootFolderController",
        "rootFolderViewController",
        NULL,
    };
    for (int i = 0; i < 2; i++) {
        uint64_t root = roots[i];
        if (!r_is_objc_ptr(root)) continue;
        for (int s = 0; sels[s]; s++) {
            uint64_t fc = gl_safe_msg(root, sels[s], 0, 0, 0, 0);
            if (r_is_objc_ptr(fc)) return fc;
        }
    }
    return 0;
}

static uint64_t gl_current_root_list_view_ios26_legacy(uint64_t ctrl)
{
    uint64_t list = 0;
    if (gl_safe_msg(ctrl, "hasOpenFolder", 0, 0, 0, 0)) {
        list = gl_safe_msg(ctrl, "currentFolderIconList", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconList", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentIconListView", 0, 0, 0, 0);
    return list;
}

static uint64_t gl_current_root_list_view(uint64_t ctrl, uint64_t mgr)
{
    uint64_t list = 0;
    if (gl_safe_msg(ctrl, "hasOpenFolder", 0, 0, 0, 0)) {
        list = gl_safe_msg(ctrl, "currentFolderIconList", 0, 0, 0, 0);
        if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentFolderIconListView", 0, 0, 0, 0);
    }

    uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(rootFC, "currentIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(rootFC, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(rootFC, "currentIconList", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconList", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(ctrl, "currentIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(mgr, "currentRootIconListView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(list)) list = gl_safe_msg(mgr, "currentIconListView", 0, 0, 0, 0);
    return list;
}

// Build a group: capture the live icon views on the given list view, record
// their grid frames, and attach one animator + 3 behaviors to them.
//
// Memory: animator/icons/iconFrames/group are each allocated with a +1
// reference and released exactly once at the end of the success path. The
// group dictionary retains animator/icons/liveFrames internally, so we do
// not keep our own references beyond this function.
static bool gl_build_group(uint64_t groups,
                           uint64_t listView,
                           uint64_t iconViewCls,
                           GravityLiteConfig config,
                           bool isDock)
{
    enum { ICON_CAP = 256 };
    uint64_t iconViews[ICON_CAP] = {0};
    int iconCount = sb_collect_views_main(listView, iconViewCls, iconViews, ICON_CAP);
    if (iconCount <= 0) {
        printf("[GRAVITY] No icon views on that page; skipping.\n");
        return false;
    }

    uint64_t icons = gl_new_remote("NSMutableArray");
    uint64_t iconFrames = gl_new_remote("NSMutableArray");
    if (!r_is_objc_ptr(icons) || !r_is_objc_ptr(iconFrames)) {
        if (r_is_objc_ptr(icons)) gl_release(icons);
        if (r_is_objc_ptr(iconFrames)) gl_release(iconFrames);
        return false;
    }

    GL_CGRect listBounds = {0};
    gl_get_rect(listView, "bounds", &listBounds);

    int added = 0;
    uint32_t oldSettle = r_settle_us(0);
    for (int i = 0; i < iconCount; i++) {
        uint64_t icon = iconViews[i];
        if (!r_is_objc_ptr(icon) || gl_view_is_hidden(icon)) continue;

        GL_CGRect iconBounds;
        GL_CGRect homeFrame;
        if (!gl_get_rect(icon, "bounds", &iconBounds) || !gl_rect_valid(iconBounds)) continue;
        if (!gl_get_rect(icon, "frame", &homeFrame) || !gl_rect_valid(homeFrame)) continue;

        gl_reset_transform(icon);
        gl_array_add(icons, icon);
        gl_array_add(iconFrames, gl_value_with_rect(homeFrame));
        added++;
    }
    r_settle_us(oldSettle);

    if (added <= 0) {
        printf("[GRAVITY] No visible icons found for this group.\n");
        gl_release(icons);
        gl_release(iconFrames);
        return false;
    }

    uint64_t animator = gl_animator_for_reference_view(listView);
    if (!r_is_objc_ptr(animator)) {
        printf("[GRAVITY] Could not start physics for this icon group.\n");
        gl_release(icons);
        gl_release(iconFrames);
        return false;
    }

    gl_attach_behaviors(animator, icons, config);

    uint64_t group = gl_new_remote("NSMutableDictionary");
    if (!r_is_objc_ptr(group)) {
        gl_release(animator);
        gl_release(icons);
        gl_release(iconFrames);
        return false;
    }

    gl_dict_set(group, s_key_animator, animator);
    gl_dict_set(group, s_key_icons, icons);
    gl_dict_set(group, s_key_listView, listView);
    gl_dict_set(group, s_key_liveFrames, iconFrames);
    gl_array_add(groups, group);

    uint64_t isRunning = gl_safe_msg(animator, "isRunning", 0, 0, 0, 0);
    uint64_t behaviorCount = gl_array_count(gl_safe_msg(animator, "behaviors", 0, 0, 0, 0));
    printf("[GRAVITY] Physics attached to %s: %d live icon(s) (%.0f×%.0f pt), physics=%s behaviors=%llu\n",
           isDock ? "dock" : "home screen",
           added,
           listBounds.w, listBounds.h,
           isRunning ? "running" : "starting",
           behaviorCount);

    gl_release(group);
    gl_release(animator);
    gl_release(icons);
    gl_release(iconFrames);
    return true;
}

bool gravitylite_stop_in_session(void)
{
    printf("[GRAVITY] stop_in_session called (active=%d)\n",
           __atomic_load_n(&s_gravity_active, __ATOMIC_RELAXED));
    __atomic_store_n(&s_gravity_active, 0, __ATOMIC_SEQ_CST);

    // Stop the poller before restoring frames below. Clearing the flag is a
    // cheap, non-blocking signal; the join is handed to a background queue
    // because this path runs on the main thread when the user deactivates
    // the tweak and gl_poller_stop() can wait up to ~1s.
    __atomic_store_n(&s_poller_running, 0, __ATOMIC_SEQ_CST);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gl_poller_stop();
    });

    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));

    uint64_t ctrl = gl_icon_controller();
    if (!r_is_objc_ptr(ctrl)) {
        printf("[GRAVITY] stop: SBIconController missing\n");
        return false;
    }

    uint64_t state = gl_get_state(ctrl);
    if (!r_is_objc_ptr(state)) {
        printf("[GRAVITY] stop: no state to restore\n");
        return true;
    }

    uint64_t groups = gl_dict_get(state, s_key_groups);
    uint64_t count = gl_array_count(groups);
    if (count > 64) count = 64;
    int restoredIcons = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t group = gl_array_object(groups, i);
        uint64_t animator  = gl_dict_get(group, s_key_animator);
        uint64_t icons     = gl_dict_get(group, s_key_icons);
        uint64_t liveFrames = gl_dict_get(group, s_key_liveFrames);
        uint64_t listView  = gl_dict_get(group, s_key_listView);

        if (r_is_objc_ptr(animator)) {
            r_msg2_main(animator, "removeAllBehaviors", 0, 0, 0, 0);
        }

        uint64_t n = gl_array_count(icons);
        uint64_t fn = gl_array_count(liveFrames);
        if (n > fn) n = fn;
        if (n > 256) n = 256;
        for (uint64_t j = 0; j < n; j++) {
            uint64_t item = gl_array_object(icons, j);
            GL_CGRect frame;
            if (!r_is_objc_ptr(item)) continue;
            gl_reset_transform(item);
            if (gl_rect_from_value(gl_array_object(liveFrames, j), &frame) &&
                gl_rect_valid(frame)) {
                gl_set_rect(item, "setFrame:", frame);
            }
            restoredIcons++;
        }

        if (r_is_objc_ptr(listView)) {
            gl_set_double(listView, "setAlpha:", 1.0);
            gl_layout_list_view(listView);
            gl_safe_msg(listView, "setNeedsLayout", 0, 0, 0, 0);
            gl_safe_msg(listView, "layoutIfNeeded", 0, 0, 0, 0);
        }
    }
    gl_set_state(ctrl, 0);
    printf("[GRAVITY] Restored %d icons to the home screen.\n", restoredIcons);
    return true;
}

bool gravitylite_apply_in_session(GravityLiteConfig config)
{
    // Physical parameter clamps. Negative values get the default; explicit
    // 0.0 is preserved.
    if (config.magnitude <= 0.0) config.magnitude = 1.0;
    if (config.bounce < 0.0) config.bounce = 0.3;
    if (config.bounce > 1.0) config.bounce = 1.0;
    if (config.friction < 0.0) config.friction = 0.2;
    if (config.friction > 1.0) config.friction = 1.0;
    if (config.resistance < 0.0) config.resistance = 0.0;
    if (config.angularResistance < 0.0) config.angularResistance = 0.0;
    if (config.explosionForce <= 0.0) config.explosionForce = 1.0;

    gl_keys_init();

    uint64_t ctrl = gl_icon_controller();
    if (!r_is_objc_ptr(ctrl)) {
        printf("[GRAVITY] SBIconController missing\n");
        return false;
    }

    // If old state exists, clean it up before proceeding. Abort on failure
    // so the caller can decide what to do.
    if (r_is_objc_ptr(gl_get_state(ctrl))) {
        if (!gravitylite_stop_in_session()) {
            printf("[GRAVITY] apply: could not clean previous session; aborting\n");
            return false;
        }
    }

    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));

    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(iconViewCls)) {
        printf("[GRAVITY] SpringBoard icon classes not found.\n");
        return false;
    }
    int iosMajor = gl_remote_ios_major();
    if (iosMajor > 0) {
        printf("[GRAVITY] Using iOS %d live icon path.\n", iosMajor);
    } else {
        printf("[GRAVITY] Could not determine iOS major version; using live icon path.\n");
    }
    printf("[GRAVITY] Resolving SpringBoard icon lists...\n");

    uint64_t mgr = gl_icon_manager(ctrl);

    uint64_t state = gl_new_remote("NSMutableDictionary");
    uint64_t groups = gl_new_remote("NSMutableArray");
    if (!r_is_objc_ptr(state) || !r_is_objc_ptr(groups)) {
        if (state) gl_release(state);
        if (groups) gl_release(groups);
        printf("[GRAVITY] state allocation failed\n");
        return false;
    }

    uint64_t listViewCls = r_class("SBIconListView");
    if (!r_is_objc_ptr(listViewCls)) {
        gl_release(groups);
        gl_release(state);
        printf("[GRAVITY] Home screen icon list class lookup failed.\n");
        return false;
    }

    int built = 0;
    bool homeBuilt = false;
    bool dockBuilt = false;

    uint64_t dockListView = gl_dock_list_view(ctrl, mgr);

    uint64_t currentListView = gl_current_root_list_view_ios26_legacy(ctrl);
    if (!r_is_objc_ptr(currentListView)) {
        currentListView = gl_current_root_list_view(ctrl, mgr);
    }
    bool currentIsListView = r_is_objc_ptr(currentListView) &&
                             r_msg2(currentListView, "isKindOfClass:", listViewCls, 0, 0, 0);
    if (currentIsListView) {
        printf("[GRAVITY] Attaching physics to the current home screen page...\n");
        if (gl_build_group(groups, currentListView, iconViewCls, config, false)) {
            built++;
            homeBuilt = true;
        } else {
            printf("[GRAVITY] Current page was not ready; checking other candidates...\n");
        }
    }

    // Fallback: if the current page could not be captured, walk every list
    // view in the windows and take the first one that yields a group.
    if (!homeBuilt) {
        enum { LV_CAP = 64 };
        uint64_t listViews[LV_CAP] = {0};
        int count = sb_collect_views_in_windows_main(listViewCls, listViews, LV_CAP);
        if (count > LV_CAP) count = LV_CAP;

        int processed = 0;
        uint64_t processedViews[LV_CAP] = {0};
        for (int i = 0; i < count && !homeBuilt; i++) {
            uint64_t listView = listViews[i];
            if (!r_is_objc_ptr(listView)) continue;
            if (gl_ptr_seen(listView, processedViews, processed)) continue;
            if (processed >= LV_CAP) break;
            processedViews[processed++] = listView;

            printf("[GRAVITY] Attaching physics to candidate %d/%d...\n", i + 1, count);
            if (gl_build_group(groups, listView, iconViewCls, config, false)) {
                built++;
                homeBuilt = true;
            }
        }
    }

    if (r_is_objc_ptr(dockListView) && config.includeDock) {
        printf("[GRAVITY] Attaching physics to dock icons...\n");
        if (gl_build_group(groups, dockListView, iconViewCls, config, true)) {
            built++;
            dockBuilt = true;
        } else {
            printf("[GRAVITY] Dock icons were not ready.\n");
        }
    }

    if (built <= 0) {
        gl_release(groups);
        gl_release(state);
        printf("[GRAVITY] No icon groups could be captured.\n");
        return false;
    }

    printf("[GRAVITY] Installing physics behaviors in SpringBoard...\n");
    gl_dict_set(state, s_key_groups, groups);
    gl_set_state(ctrl, state);
    printf("[GRAVITY] Physics started — groups=%d home=%d dock=%d\n",
           built, homeBuilt, dockBuilt);
    printf("[WARN] TO STOP GRAVITY: USE APP SWITCHER TO RETURN TO CYANIDE AND DEACTIVATE.\n");

    gl_release(groups);
    gl_release(state);
    return gravitylite_finish_apply(config);
}

bool gravitylite_explosion_in_session(double force)
{
    if (force <= 0.0) force = 1.0;

    uint64_t ctrl = gl_icon_controller();
    uint64_t state = r_is_objc_ptr(ctrl) ? gl_get_state(ctrl) : 0;
    if (!r_is_objc_ptr(state)) return false;

    uint64_t pushCls = r_class("UIPushBehavior");
    if (!r_is_objc_ptr(pushCls)) return false;

    uint64_t groups = gl_dict_get(state, s_key_groups);
    uint64_t count = gl_array_count(groups);
    if (count > 64) count = 64;

    int pulses = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t group = gl_array_object(groups, i);
        uint64_t animator  = gl_dict_get(group, s_key_animator);
        uint64_t icons     = gl_dict_get(group, s_key_icons);
        if (!r_is_objc_ptr(animator) || !r_is_objc_ptr(icons)) continue;

        gl_remove_push_behaviors(animator);

        uint64_t obj = r_msg2(pushCls, "alloc", 0, 0, 0, 0);
        uint64_t push = r_is_objc_ptr(obj)
            ? r_msg2_main(obj, "initWithItems:mode:", icons, 1, 0, 0)
            : 0;
        if (!r_is_objc_ptr(push)) continue;

        double angle = ((double)arc4random_uniform(62832) / 10000.0);
        gl_set_double(push, "setAngle:", angle);
        gl_set_double(push, "setMagnitude:", force);
        r_msg2_main(animator, "addBehavior:", push, 0, 0, 0);
        gl_set_bool(push, "setActive:", true);

        // addBehavior: is async through RemoteCall. Give it a moment to
        // settle before verifying, otherwise we may see a false negative.
        usleep(50000);

        uint64_t behaviors = gl_safe_msg(animator, "behaviors", 0, 0, 0, 0);
        bool attached = false;
        uint64_t bn = gl_array_count(behaviors);
        if (bn > 256) bn = 256;
        for (uint64_t j = 0; j < bn; j++) {
            if (gl_array_object(behaviors, j) == push) { attached = true; break; }
        }

        gl_release(push);
        if (attached) pulses++;
    }

    if (pulses > 0)
        printf("[GRAVITY] Shake pulse applied to %d group(s).\n", pulses);

    // (3) Mark recover needed.
    if (pulses > 0) {
        __atomic_store_n(&s_recover_needed, 1, __ATOMIC_SEQ_CST);
    }
    return pulses > 0;
}

bool gravitylite_update_gravity_angle_in_session(double angle, double magnitude)
{
    if (__atomic_load_n(&s_gravity_ptr_count, __ATOMIC_RELAXED) == 0) {
        // The behavior cache is empty. Either this is the first update after
        // an apply (finish_apply fills it ~0.5s in) or a RemoteCall session
        // teardown dropped it (gravitylite_forget_remote_state). Rebuild it
        // here so the tilt feed heals itself, and bring the recovery poller
        // back at the same time: it has no other restart entry point once
        // forget_remote_state has stopped it, which left the icons falling
        // with nothing to pull them back to the grid.
        //
        // Rate-limited: this runs at ~20 Hz, and while the session is still
        // down a rebuild attempt blocks on its RemoteCall timeouts, so we try
        // at most once per ~second. The attempt itself is a kernel access,
        // which is what makes SpringBoard re-make the session fds.
        if (!__atomic_load_n(&s_gravity_active, __ATOMIC_RELAXED)) return false;

        static volatile int rebuild_tick = 0;
        if (__atomic_add_fetch(&rebuild_tick, 1, __ATOMIC_RELAXED) < 20) return false;
        __atomic_store_n(&rebuild_tick, 0, __ATOMIC_RELAXED);

        gl_refresh_gravity_ptrs();
        if (__atomic_load_n(&s_gravity_ptr_count, __ATOMIC_RELAXED) == 0) return false;
        gl_poller_start();
    }

    pthread_mutex_lock(&s_gravity_refresh_mutex);
    int count = __atomic_load_n(&s_gravity_ptr_count, __ATOMIC_SEQ_CST);
    if (count <= 0) {
        pthread_mutex_unlock(&s_gravity_refresh_mutex);
        return false;
    }
    // No settle override here. r_settle_us() is a process-global with no
    // locking, and this function runs on the motion handler thread (~20 Hz)
    // while the main thread may be setting settle for a tweak apply; a
    // save/restore pair split across two threads would clobber each other.
    for (int i = 0; i < count; i++) {
        uint64_t gb = s_gravity_ptrs[i];
        if (!r_is_objc_ptr(gb)) continue;
        gl_set_double(gb, "setAngle:", angle);
        gl_set_double(gb, "setMagnitude:", magnitude);
    }
    pthread_mutex_unlock(&s_gravity_refresh_mutex);

    // Feed the recovery poller: the icons have just been pushed around, so
    // the next poll may find one fully off-screen. This used to be set on
    // every sample by the built-in tilt thread.
    __atomic_store_n(&s_recover_needed, 1, __ATOMIC_SEQ_CST);
    return true;
}

// Drop any cached remote pointers. Does NOT clear s_gravity_active or
// s_gravity_last_config_valid: the tweak is still logically active inside
// SpringBoard, and clearing those would make a later apply skip its cleanup.
void gravitylite_forget_remote_state(void)
{
    printf("[GRAVITY] forgot remote state (poller=%d gravity_ptrs=%d active=%d)\n",
           __atomic_load_n(&s_poller_running, __ATOMIC_RELAXED),
           __atomic_load_n(&s_gravity_ptr_count, __ATOMIC_RELAXED),
           __atomic_load_n(&s_gravity_active, __ATOMIC_RELAXED));

    // Stop the poller before dropping the cached pointers: it keeps sending
    // RemoteCall messages to them, and r_is_objc_ptr() only checks the
    // address range -- it cannot tell whether the object is still alive, so
    // a stale pointer here means messaging a freed object inside SpringBoard.
    gl_poller_stop();

    pthread_mutex_lock(&s_gravity_refresh_mutex);
    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));
    pthread_mutex_unlock(&s_gravity_refresh_mutex);
}

static bool gl_group_physics_alive(uint64_t group)
{
    if (!r_is_objc_ptr(group)) return false;

    uint64_t animator = gl_dict_get(group, s_key_animator);
    uint64_t items    = gl_dict_get(group, s_key_icons);
    if (!r_is_objc_ptr(animator) || !r_is_objc_ptr(items)) return false;

    uint64_t running = gl_safe_msg(animator, "isRunning", 0, 0, 0, 0);
    if (!running) return false;

    uint64_t gravityCls = r_class("UIGravityBehavior");
    if (!r_is_objc_ptr(gravityCls)) return false;

    uint64_t behaviors = gl_safe_msg(animator, "behaviors", 0, 0, 0, 0);
    uint64_t bn = gl_array_count(behaviors);
    if (bn > 64) bn = 64;
    for (uint64_t j = 0; j < bn; j++) {
        uint64_t b = gl_array_object(behaviors, j);
        if (!r_is_objc_ptr(b)) continue;
        if (r_msg2(b, "isKindOfClass:", gravityCls, 0, 0, 0) & 0xff) return true;
    }
    return false;
}

static int gl_restore_group_to_grid(uint64_t group)
{
    if (!r_is_objc_ptr(group)) return 0;

    uint64_t icons      = gl_dict_get(group, s_key_icons);
    uint64_t liveFrames = gl_dict_get(group, s_key_liveFrames);
    if (!r_is_objc_ptr(icons) || !r_is_objc_ptr(liveFrames)) return 0;

    uint64_t n = gl_array_count(icons);
    uint64_t fn = gl_array_count(liveFrames);
    if (n > fn) n = fn;
    if (n > 256) n = 256;

    int restored = 0;
    for (uint64_t j = 0; j < n; j++) {
        uint64_t icon = gl_array_object(icons, j);
        GL_CGRect homeFrame;
        if (!r_is_objc_ptr(icon)) continue;
        if (!gl_rect_from_value(gl_array_object(liveFrames, j), &homeFrame)) continue;
        if (!gl_rect_valid(homeFrame)) continue;

        gl_reset_transform(icon);
        gl_set_rect(icon, "setFrame:", homeFrame);
        restored++;
    }
    return restored;
}

// Reactivate: pull icons back to their grid frames, then re-arm the
// existing gravity behavior. Used when the physics is still alive but
// the icons have drifted.
static void gl_group_reactivate(uint64_t group, GravityLiteConfig config)
{
    if (!r_is_objc_ptr(group)) return;

    uint64_t animator = gl_dict_get(group, s_key_animator);
    uint64_t items    = gl_dict_get(group, s_key_icons);
    if (!r_is_objc_ptr(animator) || !r_is_objc_ptr(items)) return;

    gl_restore_group_to_grid(group);

    uint64_t gravityCls = r_class("UIGravityBehavior");
    if (!r_is_objc_ptr(gravityCls)) return;

    uint64_t behaviors = gl_safe_msg(animator, "behaviors", 0, 0, 0, 0);
    uint64_t bn = gl_array_count(behaviors);
    if (bn > 64) bn = 64;
    for (uint64_t j = 0; j < bn; j++) {
        uint64_t b = gl_array_object(behaviors, j);
        if (!r_is_objc_ptr(b)) continue;
        if (!(r_msg2(b, "isKindOfClass:", gravityCls, 0, 0, 0) & 0xff)) continue;

        gl_set_double(b, "setAngle:", M_PI_2);
        gl_set_double(b, "setMagnitude:", config.magnitude);
        gl_set_bool(b, "setActive:", true);

        uint64_t n = gl_array_count(items);
        if (n > 256) n = 256;
        for (uint64_t k = 0; k < n; k++) {
            uint64_t item = gl_array_object(items, k);
            if (r_is_objc_ptr(item)) {
                r_msg2_main(b, "addItem:", item, 0, 0, 0);
            }
        }
    }
}

// Rebuild: remove all behaviors, restore grid frames, then re-attach
// fresh behaviors. Used when the animator died.
static void gl_group_rebuild(uint64_t group, GravityLiteConfig config)
{
    if (!r_is_objc_ptr(group)) return;

    uint64_t animator   = gl_dict_get(group, s_key_animator);
    uint64_t icons      = gl_dict_get(group, s_key_icons);

    if (!r_is_objc_ptr(animator) || !r_is_objc_ptr(icons)) return;

    printf("[GRAVITY] group_rebuild start\n");

    r_msg2_main(animator, "removeAllBehaviors", 0, 0, 0, 0);

    int restored = gl_restore_group_to_grid(group);
    printf("[GRAVITY] group_rebuild restored %d icon(s)\n", restored);

    uint64_t n = gl_array_count(icons);
    if (n > 256) n = 256;
    for (uint64_t j = 0; j < n; j++) {
        uint64_t icon = gl_array_object(icons, j);
        if (!r_is_objc_ptr(icon)) continue;
        gl_reset_transform(icon);
    }

    gl_attach_behaviors(animator, icons, config);
    printf("[GRAVITY] group_rebuild done (icons=%llu)\n", (unsigned long long)n);
}

// Recovery: only pull back icons that are *fully* off the list view.
// Partially visible icons are left where they are, so App Library /
// Today View transitions don't yank the dock icons back to their grid
// frames.
static void gl_recover_out_of_bounds_icons(void)
{
    uint64_t ctrl = gl_icon_controller();
    uint64_t state = r_is_objc_ptr(ctrl) ? gl_get_state(ctrl) : 0;
    if (!r_is_objc_ptr(state)) return;

    uint64_t groups = gl_dict_get(state, s_key_groups);
    uint64_t count = gl_array_count(groups);
    if (count > 64) count = 64;

    int recovered = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t group = gl_array_object(groups, i);
        uint64_t icons = gl_dict_get(group, s_key_icons);
        uint64_t liveFrames = gl_dict_get(group, s_key_liveFrames);
        uint64_t listView = gl_dict_get(group, s_key_listView);
        if (!r_is_objc_ptr(icons) || !r_is_objc_ptr(liveFrames)) continue;

        GL_CGRect bounds;
        if (!gl_get_rect(listView, "bounds", &bounds) || !gl_rect_valid(bounds)) continue;

        uint64_t n = gl_array_count(icons);
        uint64_t fn = gl_array_count(liveFrames);
        if (n > fn) n = fn;
        if (n > 256) n = 256;

        for (uint64_t j = 0; j < n; j++) {
            uint64_t icon = gl_array_object(icons, j);
            GL_CGRect frame;
            if (!r_is_objc_ptr(icon)) continue;
            if (!gl_get_rect(icon, "frame", &frame)) continue;
            if (!gl_rect_valid(frame)) continue;

            bool fully_out = (frame.x + frame.w <= 0.0 ||
                              frame.y + frame.h <= 0.0 ||
                              frame.x >= bounds.w ||
                              frame.y >= bounds.h);
            if (!fully_out) continue;

            GL_CGRect homeFrame;
            if (!gl_rect_from_value(gl_array_object(liveFrames, j), &homeFrame)) continue;
            if (!gl_rect_valid(homeFrame)) continue;

            gl_reset_transform(icon);
            gl_set_rect(icon, "setFrame:", homeFrame);
            recovered++;
        }
    }

    // (5) Log only when changed.
    static int s_last_recovered = -1;
    if (recovered != s_last_recovered) {
        if (recovered > 0) {
            printf("[GRAVITY] recovered %d out-of-bounds icon(s)\n", recovered);
        }
        s_last_recovered = recovered;
    }

    // (3) Clear recover-needed flag.
    __atomic_store_n(&s_recover_needed, 0, __ATOMIC_SEQ_CST);
}

static int gravitylite_revalidate_physics(void)
{
    if (!__atomic_load_n(&s_gravity_last_config_valid, __ATOMIC_SEQ_CST)) {
        printf("[GRAVITY] revalidate: no prior apply; skipping\n");
        return 0;
    }

    for (int i = 0; i < 3; i++) {
        uint64_t ctrl = gl_icon_controller();
        if (r_is_objc_ptr(ctrl)) break;
        usleep(300000);
    }

    uint64_t ctrl = gl_icon_controller();
    uint64_t state = r_is_objc_ptr(ctrl) ? gl_get_state(ctrl) : 0;
    if (!r_is_objc_ptr(state)) return 0;

    uint64_t groups = gl_dict_get(state, s_key_groups);
    uint64_t count = gl_array_count(groups);
    if (count > 64) count = 64;

    GravityLiteConfig config = s_gravity_last_config;
    int rebuilt = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t group = gl_array_object(groups, i);
        if (!r_is_objc_ptr(group)) continue;

        if (gl_group_physics_alive(group)) {
            gl_group_reactivate(group, config);
        } else {
            gl_group_rebuild(group, config);
            rebuilt++;
        }
    }

    gl_refresh_gravity_ptrs();
    return rebuilt;
}

static bool gravitylite_finish_apply(GravityLiteConfig config)
{
    s_gravity_last_config = config;
    __atomic_store_n(&s_gravity_last_config_valid, 1, __ATOMIC_SEQ_CST);
    __atomic_store_n(&s_gravity_active, 1, __ATOMIC_SEQ_CST);
    s_gravity_last_logged_count = -1;
    // (3) Mark recover needed on apply.
    __atomic_store_n(&s_recover_needed, 1, __ATOMIC_SEQ_CST);

    // Tilt is driven by SettingsViewController's motion handler
    // (settings_start_gravity_motion), which owns the lock/blank observers
    // and gates on them itself. From here we only need to (a) fill the
    // behavior cache the angle updates write through, and (b) start the
    // recovery poller once SpringBoard has settled the new layout.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!__atomic_load_n(&s_gravity_active, __ATOMIC_SEQ_CST)) return;
        gl_refresh_gravity_ptrs();
        gl_poller_start();
    });

    return true;
}

// --------------------------------------------------------- behavior cache ---

static void gl_refresh_gravity_ptrs(void)
{
    uint64_t local_ptrs[GRAVITY_MAX_BEHAVIORS] = {0};
    int local_count = 0;

    uint64_t ctrl = gl_icon_controller();
    uint64_t state = r_is_objc_ptr(ctrl) ? gl_get_state(ctrl) : 0;
    if (r_is_objc_ptr(state)) {
        uint64_t gravityCls = r_class("UIGravityBehavior");
        if (r_is_objc_ptr(gravityCls)) {
            uint64_t groups = gl_dict_get(state, s_key_groups);
            uint64_t count = gl_array_count(groups);
            if (count > 64) count = 64;

            for (uint64_t i = 0; i < count && local_count < GRAVITY_MAX_BEHAVIORS; i++) {
                uint64_t group = gl_array_object(groups, i);
                uint64_t animator = gl_dict_get(group, s_key_animator);
                uint64_t items = gl_dict_get(group, s_key_icons);
                if (!r_is_objc_ptr(animator)) continue;

                uint64_t behaviors = gl_safe_msg(animator, "behaviors", 0, 0, 0, 0);
                uint64_t bn = gl_array_count(behaviors);
                if (bn > 64) bn = 64;
                for (uint64_t j = 0; j < bn && local_count < GRAVITY_MAX_BEHAVIORS; j++) {
                    uint64_t behavior = gl_array_object(behaviors, j);
                    if (!r_is_objc_ptr(behavior)) continue;
                    if (!(r_msg2(behavior, "isKindOfClass:", gravityCls, 0, 0, 0) & 0xff)) continue;

                    gl_set_bool(behavior, "setActive:", true);
                    uint64_t n = gl_array_count(items);
                    if (n > 256) n = 256;
                    for (uint64_t k = 0; k < n; k++) {
                        uint64_t item = gl_array_object(items, k);
                        if (r_is_objc_ptr(item)) {
                            r_msg2_main(behavior, "addItem:", item, 0, 0, 0);
                        }
                    }

                    local_ptrs[local_count++] = behavior;
                }
            }
        }
    }

    pthread_mutex_lock(&s_gravity_refresh_mutex);
    __atomic_store_n(&s_gravity_ptr_count, 0, __ATOMIC_SEQ_CST);
    memset(s_gravity_ptrs, 0, sizeof(s_gravity_ptrs));
    int capped = local_count > GRAVITY_MAX_BEHAVIORS ? GRAVITY_MAX_BEHAVIORS : local_count;
    for (int i = 0; i < capped; i++) {
        s_gravity_ptrs[i] = local_ptrs[i];
    }
    __atomic_store_n(&s_gravity_ptr_count, capped, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&s_gravity_refresh_mutex);

    if (local_count > GRAVITY_MAX_BEHAVIORS) {
        printf("[GRAVITY] warning: %d behaviors found, only %d cached\n",
               local_count, GRAVITY_MAX_BEHAVIORS);
    }

    int last = __atomic_load_n(&s_gravity_last_logged_count, __ATOMIC_RELAXED);
    if (capped != last) {
        printf("[GRAVITY] tilt target cache refreshed (%d gravity behavior(s))\n", capped);
        __atomic_store_n(&s_gravity_last_logged_count, capped, __ATOMIC_SEQ_CST);
    }
}

// ------------------------------------------------------------- home poller ---

// (1) Poller only runs when home screen is visible.
// (3) Recover only when s_recover_needed is set.
//
// Every probe below is a RemoteCall. r_settle_us() is a process-global with
// no locking, so rather than leaving settle at the configured value (50 ms
// per message in Compatible mode) we drop it to 0 for the duration of the
// tick: this loop issues ~10 remote messages, and at the default settle it
// would otherwise hold the RemoteCall lock while sleeping for most of a
// second.
static void *gl_poller_thread_main(void *arg)
{
    (void)arg;
    int tick = 0;
    while (__atomic_load_n(&s_poller_running, __ATOMIC_RELAXED)) {
        uint32_t oldSettle = r_settle_us(0);
        bool onHome = true;

        // Skip work when not on the home screen.
        uint64_t ctrl = gl_icon_controller();
        if (r_is_objc_ptr(ctrl)) {
            uint64_t mgr = gl_icon_manager(ctrl);
            uint64_t rootFC = gl_root_folder_controller(ctrl, mgr);
            uint64_t rootView = gl_safe_msg(rootFC, "rootFolderView", 0, 0, 0, 0);
            if (r_is_objc_ptr(rootView)) {
                int idx = r_responds_main(rootView, "currentPageIndex")
                    ? (int)r_msg2_main(rootView, "currentPageIndex", 0, 0, 0, 0)
                    : -1;
                int cnt = r_responds_main(rootView, "iconListViewCount")
                    ? (int)r_msg2_main(rootView, "iconListViewCount", 0, 0, 0, 0)
                    : 0;
                onHome = (idx > 100 && idx <= 100 + cnt);
            }
        }

        if (onHome && ++tick >= 4) {
            tick = 0;
            // Self-heal the behavior cache: it is zeroed by
            // gravitylite_forget_remote_state() and can also be lost when
            // SpringBoard rebuilds its animators.
            if (__atomic_load_n(&s_gravity_ptr_count, __ATOMIC_RELAXED) == 0) {
                gl_refresh_gravity_ptrs();
            }
            if (__atomic_load_n(&s_recover_needed, __ATOMIC_RELAXED)) {
                gl_recover_out_of_bounds_icons();
            }
        }
        if (!onHome) tick = 0;

        r_settle_us(oldSettle);

        usleep(onHome ? 300000 : 1000000);   // 1s off-home
    }
    __atomic_store_n(&s_poller_exited, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

// Joins/detaches the current poller thread. Caller must hold
// s_poller_lifecycle_mutex.
static void gl_poller_stop_locked(void)
{
    bool was_running = __atomic_load_n(&s_poller_running, __ATOMIC_RELAXED) != 0;
    if (was_running) {
        __atomic_store_n(&s_poller_exited, 0, __ATOMIC_SEQ_CST);
        __atomic_store_n(&s_poller_running, 0, __ATOMIC_SEQ_CST);
    }
    // The flag can already be clear: gravitylite_stop_in_session() clears it
    // first so the thread starts exiting without blocking the main thread,
    // and the later join lands here. The handle still needs retiring.
    if (!was_running && !s_poller_thread_valid) return;

    for (int i = 0; i < 100; i++) {
        if (__atomic_load_n(&s_poller_exited, __ATOMIC_RELAXED)) break;
        usleep(10000);
    }
    if (s_poller_thread_valid) {
        // Don't join ourselves.
        if (pthread_self() != s_poller_thread) {
            if (__atomic_load_n(&s_poller_exited, __ATOMIC_RELAXED)) {
                pthread_join(s_poller_thread, NULL);
            } else {
                printf("[GRAVITY] poller thread did not exit in time; detaching\n");
                pthread_detach(s_poller_thread);
            }
        }
        s_poller_thread_valid = 0;
    }
}

static void gl_poller_start(void)
{
    pthread_mutex_lock(&s_poller_lifecycle_mutex);

    // Retire a thread whose stop is still joining on a background queue,
    // otherwise pthread_create() below would overwrite a live handle. No-op
    // when there is nothing to retire, so this is normally free.
    if (s_poller_thread_valid) gl_poller_stop_locked();

    if (!__atomic_load_n(&s_poller_running, __ATOMIC_RELAXED)) {
        __atomic_store_n(&s_poller_exited, 0, __ATOMIC_SEQ_CST);
        __atomic_store_n(&s_poller_running, 1, __ATOMIC_SEQ_CST);
        if (pthread_create(&s_poller_thread, NULL, gl_poller_thread_main, NULL) != 0) {
            __atomic_store_n(&s_poller_running, 0, __ATOMIC_SEQ_CST);
            s_poller_thread_valid = 0;
            printf("[GRAVITY] poller could not start\n");
        } else {
            s_poller_thread_valid = 1;
            printf("[GRAVITY] poller running\n");
        }
    }

    pthread_mutex_unlock(&s_poller_lifecycle_mutex);
}

static void gl_poller_stop(void)
{
    pthread_mutex_lock(&s_poller_lifecycle_mutex);
    gl_poller_stop_locked();
    pthread_mutex_unlock(&s_poller_lifecycle_mutex);
}