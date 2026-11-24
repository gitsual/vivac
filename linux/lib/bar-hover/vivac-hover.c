// vivac-hover: a Waybar CFFI module that opens a bar panel when the pointer
// rests on its button, as a click does. Waybar 0.16 has click, scroll and
// double-click actions but nothing on hover, so this module draws nothing and
// listens instead: it finds the bar's buttons by the name Waybar gives their
// label (the module's name, "custom/x" written "custom-x") and watches the
// GtkEventBox each label sits in.
//
// Config (every value as Waybar passes it, JSON-encoded):
//   "launcher"  absolute path of vivac-panel
//   "dwell"     milliseconds the pointer has to rest before a panel opens
//   any other key that is a button name, or "name.id" for one of several
//   modules of a name: the panel and its arguments, for example
//   "pulseaudio": "sound", "custom-system": "system cpu",
//   "network.wired": "network ethernet"
//
// A button it watches shows no tooltip: its panel takes that place.
//
// What it asks of vivac-panel: "<panel> --hover" once the pointer has rested
// on the button, "<panel> --hover-leave" when it leaves the button. The panel
// itself decides when to close (docs: lib/vivacpanel/kit.py, Panel).
#include <stdlib.h>
#include <string.h>

#include "waybar_cffi_module.h"

const size_t wbcffi_version = 2;

typedef struct {
    GtkWidget *slot;
    GHashTable *panels;  // button name -> panel arguments
    char *launcher;
    guint dwell;
    guint scan_id;
    guint scans;
    guint open_id;
    char *pending;  // the panel waiting out the dwell
    char *open;     // the panel opened by hover, until the pointer leaves
} Hover;

#define HOOKED "vivac-hover-panel"

// A value as Waybar passes it (ABI 2: JSON through toStyledString, so with a
// trailing newline), unquoted when it is a string, trimmed otherwise.
static char *unquote(const char *value) {
    char *text = g_strstrip(g_strdup(value));
    size_t n = strlen(text);
    if (n >= 2 && text[0] == '"' && text[n - 1] == '"') {
        char *inner = g_strndup(text + 1, n - 2);
        g_free(text);
        return inner;
    }
    return text;
}

static void launch(Hover *h, const char *panel, const char *flag) {
    gchar **words = g_strsplit(panel, " ", -1);
    GPtrArray *argv = g_ptr_array_new();
    g_ptr_array_add(argv, h->launcher);
    for (gchar **w = words; *w; w++)
        if (**w) g_ptr_array_add(argv, *w);
    g_ptr_array_add(argv, (gpointer)flag);
    g_ptr_array_add(argv, NULL);
    GError *error = NULL;
    if (!g_spawn_async(NULL, (gchar **)argv->pdata, NULL, G_SPAWN_DEFAULT, NULL, NULL, NULL, &error)) {
        g_warning("vivac-hover: %s", error->message);
        g_error_free(error);
    }
    g_ptr_array_free(argv, TRUE);
    g_strfreev(words);
}

static void cancel_open(Hover *h) {
    if (h->open_id) g_source_remove(h->open_id);
    h->open_id = 0;
    g_clear_pointer(&h->pending, g_free);
}

static gboolean rested(gpointer data) {
    Hover *h = data;
    h->open_id = 0;
    launch(h, h->pending, "--hover");
    g_free(h->open);
    h->open = h->pending;
    h->pending = NULL;
    return G_SOURCE_REMOVE;
}

static gboolean entered(GtkWidget *box, GdkEventCrossing *event, gpointer data) {
    Hover *h = data;
    if (event->detail == GDK_NOTIFY_INFERIOR) return FALSE;  // from its own label
    const char *panel = g_object_get_data(G_OBJECT(box), HOOKED);
    cancel_open(h);
    h->pending = g_strdup(panel);
    h->open_id = g_timeout_add(h->dwell, rested, h);
    return FALSE;  // Waybar's own hover styling still runs
}

static gboolean left(GtkWidget *box, GdkEventCrossing *event, gpointer data) {
    Hover *h = data;
    if (event->detail == GDK_NOTIFY_INFERIOR) return FALSE;  // onto its own label
    const char *panel = g_object_get_data(G_OBJECT(box), HOOKED);
    cancel_open(h);
    if (h->open && strcmp(h->open, panel) == 0) {
        launch(h, panel, "--hover-leave");
        g_clear_pointer(&h->open, g_free);
    }
    return FALSE;
}

// A button that opens its panel on hover does not also show Waybar's tooltip:
// the panel is what the pointer is there for. Stopping the emission keeps
// GTK's own handler, which would draw the tooltip, from running.
static gboolean no_tooltip(GtkWidget *widget, gint x, gint y, gboolean keyboard, GtkTooltip *tip, gpointer data) {
    (void)x, (void)y, (void)keyboard, (void)tip, (void)data;
    g_signal_stop_emission_by_name(widget, "query-tooltip");
    return FALSE;
}

// The panel for a button: "name.id" first (Waybar adds a module's #id to its
// label as a style class: network#wired is "network" with the class "wired"),
// then the name alone.
static const char *panel_for(Hover *h, GtkWidget *widget) {
    const char *name = gtk_widget_get_name(widget);
    if (!name) return NULL;
    GList *classes = gtk_style_context_list_classes(gtk_widget_get_style_context(widget));
    const char *panel = NULL;
    for (GList *c = classes; c && !panel; c = c->next) {
        char *key = g_strdup_printf("%s.%s", name, (const char *)c->data);
        panel = g_hash_table_lookup(h->panels, key);
        g_free(key);
    }
    g_list_free(classes);
    return panel ? panel : g_hash_table_lookup(h->panels, name);
}

static void hook(GtkWidget *widget, gpointer data) {
    Hover *h = data;
    const char *panel = panel_for(h, widget);
    // The event box is the label's parent for most modules; custom/* modules
    // (AIconLabel) put a box with an icon in between, so look a few levels up.
    GtkWidget *parent = gtk_widget_get_parent(widget);
    for (int up = 0; parent && !GTK_IS_EVENT_BOX(parent) && up < 3; up++) parent = gtk_widget_get_parent(parent);
    if (panel && parent && GTK_IS_EVENT_BOX(parent) && !g_object_get_data(G_OBJECT(parent), HOOKED)) {
        g_object_set_data_full(G_OBJECT(parent), HOOKED, g_strdup(panel), g_free);
        gtk_widget_add_events(parent, GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
        g_signal_connect(parent, "enter-notify-event", G_CALLBACK(entered), h);
        g_signal_connect(parent, "leave-notify-event", G_CALLBACK(left), h);
        g_signal_connect(widget, "query-tooltip", G_CALLBACK(no_tooltip), NULL);
        g_signal_connect(parent, "query-tooltip", G_CALLBACK(no_tooltip), NULL);
    }
    if (GTK_IS_CONTAINER(widget)) gtk_container_forall(GTK_CONTAINER(widget), hook, h);
}

// The other modules are built around this one, so the buttons are looked
// for from the bar's window once it exists, a few times while the bar settles.
static gboolean scan(gpointer data) {
    Hover *h = data;
    GtkWidget *top = gtk_widget_get_toplevel(h->slot);
    if (gtk_widget_is_toplevel(top)) hook(top, h);
    if (++h->scans < 10) return G_SOURCE_CONTINUE;
    h->scan_id = 0;
    return G_SOURCE_REMOVE;
}

void *wbcffi_init(const wbcffi_init_info *info, const wbcffi_config_entry *entries, size_t count) {
    Hover *h = g_new0(Hover, 1);
    h->panels = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    h->dwell = 300;
    for (size_t i = 0; i < count; i++) {
        const char *key = entries[i].key;
        if (strcmp(key, "module_path") == 0 || strcmp(key, "actions") == 0) continue;
        if (strcmp(key, "launcher") == 0) {
            h->launcher = unquote(entries[i].value);
        } else if (strcmp(key, "dwell") == 0) {
            char *number = unquote(entries[i].value);
            long ms = strtol(number, NULL, 10);
            g_free(number);
            h->dwell = ms >= 50 && ms <= 5000 ? (guint)ms : 300;
        } else {
            g_hash_table_insert(h->panels, g_strdup(key), unquote(entries[i].value));
        }
    }
    if (!h->launcher || !g_path_is_absolute(h->launcher)) {
        g_warning("vivac-hover: \"launcher\" must be an absolute path");
        g_hash_table_destroy(h->panels);
        g_free(h->launcher);
        g_free(h);
        return NULL;
    }
    h->slot = GTK_WIDGET(info->get_root_widget(info->obj));
    h->scan_id = g_timeout_add(200, scan, h);
    return h;
}

void wbcffi_deinit(void *instance) {
    Hover *h = instance;
    if (h->scan_id) g_source_remove(h->scan_id);
    cancel_open(h);
    g_free(h->open);
    g_hash_table_destroy(h->panels);
    g_free(h->launcher);
    g_free(h);
}
