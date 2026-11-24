#!/usr/bin/env bash
set -Eeuo pipefail

# lib/bar-hover: the Waybar CFFI module that opens a bar panel when the
# pointer rests on its button, the way a click opens it. Waybar 0.16 has no
# hover action of its own. Built here and loaded by a small GTK 3 harness that
# lays out a bar as Waybar does (a GtkEventBox holding a label named after the
# module; for custom/* modules a box with an icon and that label in between) and plays the pointer over it under Xvfb: resting on a mapped button
# opens its panel after the dwell, leaving tells that panel the pointer left,
# passing over without resting opens nothing, an unmapped button is ignored,
# moving onto the label inside a button is not a leave, and a button that
# opens a panel on hover no longer shows Waybar's old tooltip.

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
source_dir="$repo_root/lib/bar-hover"
fail() {
	printf '%s\n' "$1" >&2
	exit 1
}
for tool in gcc pkg-config Xvfb; do
	command -v "$tool" >/dev/null || {
		printf 'bar-hover: skipped, %s is not installed\n' "$tool"
		exit 0
	}
done
pkg-config --exists gtk+-3.0 || {
	printf 'bar-hover: skipped, no GTK 3 headers\n'
	exit 0
}
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vivac-hover.XXXXXX")"
xvfb=''
cleanup() {
	[[ -z "$xvfb" ]] || kill "$xvfb" 2>/dev/null || true
	rm -rf -- "$sandbox"
}
trap cleanup EXIT

"$repo_root/scripts/build-bar-hover.sh" --output "$sandbox/vivac-hover.so" >/dev/null || fail 'the module did not build'
nm -D --defined-only "$sandbox/vivac-hover.so" | grep -q ' wbcffi_init$' || fail 'wbcffi_init is not exported'
nm -D --defined-only "$sandbox/vivac-hover.so" | grep -q ' wbcffi_version$' || fail 'wbcffi_version is not exported'

cat >"$sandbox/launcher" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${0%/*}/calls"
SH
chmod +x "$sandbox/launcher"

cat >"$sandbox/harness.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "waybar_cffi_module.h"

static GtkContainer *root_widget(wbcffi_module *m) { return GTK_CONTAINER(m); }
static void queue_update(wbcffi_module *m) { (void)m; }

static void spin(int ms) {
    gint64 end = g_get_monotonic_time() + ms * 1000;
    while (g_get_monotonic_time() < end) g_main_context_iteration(NULL, FALSE);
}
static void cross(GtkWidget *box, GdkEventType type, GdkNotifyType detail) {
    GdkEvent *ev = gdk_event_new(type);
    ev->crossing.window = g_object_ref(gtk_widget_get_window(box));
    ev->crossing.detail = detail;
    ev->crossing.mode = GDK_CROSSING_NORMAL;
    gtk_widget_event(box, ev);
    gdk_event_free(ev);
}
static GtkWidget *labels[8];
static int nlabels;
static GtkWidget *button_with(GtkWidget *bar, const char *name, const char *id);
static GtkWidget *button(GtkWidget *bar, const char *name) { return button_with(bar, name, NULL); }
/* ID is the module's #id, which Waybar adds to the label as a style class
   (network#wired: a label named "network" with the class "wired"). */
static GtkWidget *button_with(GtkWidget *bar, const char *name, const char *id) {
    GtkWidget *box = gtk_event_box_new(), *label = gtk_label_new(name);
    gtk_widget_set_name(label, name);
    if (id) gtk_style_context_add_class(gtk_widget_get_style_context(label), id);
    gtk_widget_set_tooltip_text(label, "Waybar's own tooltip");
    labels[nlabels++] = label;
    if (strncmp(name, "custom-", 7) == 0) {
        /* custom/* modules are AIconLabels: event box > box > icon + label */
        GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_box_pack_start(GTK_BOX(inner), gtk_image_new(), FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(inner), label, FALSE, FALSE, 0);
        gtk_container_add(GTK_CONTAINER(box), inner);
    } else {
        gtk_container_add(GTK_CONTAINER(box), label);
    }
    gtk_box_pack_start(GTK_BOX(bar), box, FALSE, FALSE, 0);
    return box;
}

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL), *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_container_add(GTK_CONTAINER(win), bar);
    GtkWidget *sound = button(bar, "pulseaudio");
    GtkWidget *system = button(bar, "custom-system");
    GtkWidget *phone = button(bar, "custom-phone");
    GtkWidget *wired = button_with(bar, "network", "wired");
    GtkWidget *wireless = button_with(bar, "network", "wireless");
    GtkWidget *slot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_pack_start(GTK_BOX(bar), slot, FALSE, FALSE, 0);
    gtk_widget_show_all(win);
    spin(100);

    void *handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    void *(*init)(const wbcffi_init_info *, const wbcffi_config_entry *, size_t) = dlsym(handle, "wbcffi_init");
    void (*deinit)(void *) = dlsym(handle, "wbcffi_deinit");
    char launcher[4096];
    snprintf(launcher, sizeof launcher, "\"%s\"\n", argv[2]);  /* as Waybar passes it: toStyledString */
    wbcffi_init_info info = {(wbcffi_module *)slot, "0.16.0", root_widget, queue_update};
    wbcffi_config_entry config[] = {
        {"module_path", "\"/x.so\"\n"}, {"launcher", launcher}, {"dwell", "60\n"},
        {"pulseaudio", "\"sound\"\n"}, {"custom-system", "\"system cpu\"\n"},
        {"network.wired", "\"network ethernet\"\n"}, {"network.wireless", "\"network wifi\"\n"},
    };
    void *instance = init(&info, config, sizeof config / sizeof *config);
    if (!instance) return 3;
    spin(300);

    cross(sound, GDK_ENTER_NOTIFY, GDK_NOTIFY_NONLINEAR);   /* rest on the sound button */
    spin(250);
    cross(sound, GDK_LEAVE_NOTIFY, GDK_NOTIFY_INFERIOR);    /* onto its label: still inside */
    spin(100);
    cross(sound, GDK_LEAVE_NOTIFY, GDK_NOTIFY_NONLINEAR);   /* and away */
    spin(250);
    cross(system, GDK_ENTER_NOTIFY, GDK_NOTIFY_NONLINEAR);  /* passing over, no rest */
    spin(20);
    cross(system, GDK_LEAVE_NOTIFY, GDK_NOTIFY_NONLINEAR);
    spin(250);
    cross(phone, GDK_ENTER_NOTIFY, GDK_NOTIFY_NONLINEAR);   /* a button with no panel */
    spin(250);
    cross(phone, GDK_LEAVE_NOTIFY, GDK_NOTIFY_NONLINEAR);
    cross(system, GDK_ENTER_NOTIFY, GDK_NOTIFY_NONLINEAR);  /* a panel with an argument */
    spin(250);
    cross(system, GDK_LEAVE_NOTIFY, GDK_NOTIFY_NONLINEAR);
    cross(wired, GDK_ENTER_NOTIFY, GDK_NOTIFY_NONLINEAR);   /* one module name, told apart by its #id */
    spin(250);
    cross(wired, GDK_LEAVE_NOTIFY, GDK_NOTIFY_NONLINEAR);
    cross(wireless, GDK_ENTER_NOTIFY, GDK_NOTIFY_NONLINEAR);
    spin(250);
    /* The old tooltip gives way to the panel on a mapped button only. */
    guint query = g_signal_lookup("query-tooltip", GTK_TYPE_WIDGET);
    for (int i = 0; i < nlabels; i++)
        printf("tooltip %s %s\n", gtk_widget_get_name(labels[i]),
               g_signal_has_handler_pending(labels[i], query, 0, FALSE) ? "silenced" : "kept");
    fflush(stdout);
    deinit(instance);
    spin(100);
    return 0;
}
C
# shellcheck disable=SC2046  # pkg-config prints several words on purpose
gcc -o "$sandbox/harness" "$sandbox/harness.c" -I"$source_dir" $(pkg-config --cflags --libs gtk+-3.0) -ldl ||
	fail 'the harness did not build'

display=":$((90 + RANDOM % 100))"
Xvfb "$display" -screen 0 640x200x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
DISPLAY="$display" GDK_BACKEND=x11 timeout 20 "$sandbox/harness" "$sandbox/vivac-hover.so" "$sandbox/launcher" >"$sandbox/out" ||
	fail "the harness failed ($?)"
tooltips="$(grep '^tooltip ' "$sandbox/out")"
[[ "$tooltips" == $'tooltip pulseaudio silenced\ntooltip custom-system silenced\ntooltip custom-phone kept\ntooltip network silenced\ntooltip network silenced' ]] ||
	fail "tooltips: $tooltips"
sleep 0.3 # the last launch is asynchronous

expected=$'sound --hover\nsound --hover-leave\nsystem cpu --hover\nsystem cpu --hover-leave\nnetwork ethernet --hover\nnetwork ethernet --hover-leave\nnetwork wifi --hover'
calls="$(cat "$sandbox/calls" 2>/dev/null || true)"
[[ "$calls" == "$expected" ]] || fail "panels asked for:
$calls
expected:
$expected"
printf 'bar-hover: rest opens, leave tells, passing by and unmapped buttons do nothing\n'
