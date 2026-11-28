#include <gtk/gtk.h>
#include <gtk-layer-shell.h>
#include <math.h>
#include <string.h>

static const char *state_path;
static gint64 recording_started;

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h)
{
    double r = h / 2;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI_2, G_PI_2);
    cairo_arc(cr, x + r, y + r, r, G_PI_2, 3 * G_PI_2);
    cairo_close_path(cr);
}

static void draw_kitt(cairo_t *cr, double width, double height, double elapsed)
{
    const int segments = 8;
    const double segment_width = (width - 14) / segments;
    const double position = (segments - 1) * (1 - cos(elapsed * G_PI / 0.72)) / 2;

    cairo_rectangle(cr, 1, 5, width - 2, height - 10);
    cairo_set_source_rgba(cr, 0.045, 0.048, 0.056, 0.96);
    cairo_fill_preserve(cr);
    cairo_set_source_rgb(cr, 0.29, 0.31, 0.35);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);

    for (int segment = 0; segment < segments; segment++) {
        const double distance = segment - position;
        const double intensity = exp(-0.82 * distance * distance);
        const double x = 8 + segment * segment_width;
        cairo_rectangle(cr, x, height / 2 - 6, segment_width - 3, 12);
        cairo_set_source_rgb(cr, 0.14 + 0.86 * intensity, 0.01 + 0.52 * intensity * intensity,
                            0.02 + 0.25 * intensity * intensity);
        cairo_fill(cr);

        cairo_rectangle(cr, x, height / 2 - 6, segment_width - 3, 2);
        cairo_set_source_rgba(cr, 1, 0.63, 0.53, 0.22 * intensity);
        cairo_fill(cr);
    }
}

static gboolean draw_scanner(GtkWidget *widget, cairo_t *cr, gpointer style)
{
    const double width = 166;
    const double height = 30;
    const double elapsed = (g_get_monotonic_time() - recording_started) / 1e6;
    const double eye = width / 2 - (width / 2 - 21) * cos(elapsed * G_PI / 0.85);

    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    cairo_scale(cr, gtk_widget_get_allocated_width(widget) / width,
                    gtk_widget_get_allocated_height(widget) / height);

    if (GPOINTER_TO_INT(style)) {
        draw_kitt(cr, width, height, elapsed);
        return FALSE;
    }

    rounded_rect(cr, 1, 4, width - 2, height - 8);
    cairo_set_source_rgba(cr, 0.03, 0.015, 0.02, 0.94);
    cairo_fill_preserve(cr);
    cairo_set_source_rgb(cr, 0.31, 0.13, 0.15);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);

    rounded_rect(cr, 8, height / 2 - 6, width - 16, 12);
    cairo_clip(cr);
    cairo_set_source_rgb(cr, 0.20, 0.015, 0.035);
    cairo_paint(cr);

    cairo_pattern_t *beam = cairo_pattern_create_linear(eye - 36, 0, eye + 36, 0);
    cairo_pattern_add_color_stop_rgba(beam, 0, 0.9, 0.02, 0.06, 0);
    cairo_pattern_add_color_stop_rgba(beam, 0.39, 1, 0.07, 0.13, 0.73);
    cairo_pattern_add_color_stop_rgb(beam, 0.5, 1, 0.83, 0.79);
    cairo_pattern_add_color_stop_rgba(beam, 0.61, 1, 0.07, 0.13, 0.73);
    cairo_pattern_add_color_stop_rgba(beam, 1, 0.9, 0.02, 0.06, 0);
    cairo_set_source(cr, beam);
    cairo_paint(cr);
    cairo_pattern_destroy(beam);
    return FALSE;
}

static gboolean animate(GtkWidget *widget, GdkFrameClock *clock, gpointer unused)
{
    gtk_widget_queue_draw(widget);
    return G_SOURCE_CONTINUE;
}

static gboolean update_visibility(gpointer data)
{
    GtkWidget *window = GTK_WIDGET(data);
    g_autofree char *contents = NULL;
    gboolean recording = FALSE;
    if (g_file_get_contents(state_path, &contents, NULL, NULL)) {
        g_strstrip(contents);
        recording = strcmp(contents, "recording") == 0 || strcmp(contents, "streaming") == 0;
    }

    if (recording && !gtk_widget_get_visible(window)) {
        recording_started = g_get_monotonic_time();
        gtk_widget_show_all(window);
    } else if (!recording && gtk_widget_get_visible(window)) {
        gtk_widget_hide(window);
    }
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 3 ||
        (argc == 3 && strcmp(argv[2], "cylon") != 0 && strcmp(argv[2], "kitt") != 0)) {
        g_printerr("Usage: %s VOXTYPE_STATE_FILE [cylon|kitt]\n", argv[0]);
        return 2;
    }
    gboolean kitt = argc == 3 && strcmp(argv[2], "kitt") == 0;
    state_path = argv[1];
    gtk_init(&argc, &argv);
    if (!gtk_layer_is_supported()) {
        g_printerr("The Wayland compositor does not support layer-shell.\n");
        return 1;
    }

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_widget_set_app_paintable(window, TRUE);
    gtk_widget_set_visual(window, gdk_screen_get_rgba_visual(gtk_widget_get_screen(window)));
    gtk_layer_init_for_window(GTK_WINDOW(window));
    gtk_layer_set_namespace(GTK_WINDOW(window), "voxtype-recording-indicator");
    gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_OVERLAY);
    gtk_layer_set_exclusive_zone(GTK_WINDOW(window), -1);
    gtk_layer_set_keyboard_mode(GTK_WINDOW(window), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);

    cairo_region_t *empty = cairo_region_create();
    gtk_widget_input_shape_combine_region(window, empty);
    cairo_region_destroy(empty);

    GtkWidget *canvas = gtk_drawing_area_new();
    gtk_widget_set_size_request(canvas, 200, 36);
    gtk_container_add(GTK_CONTAINER(window), canvas);
    g_signal_connect(canvas, "draw", G_CALLBACK(draw_scanner), GINT_TO_POINTER(kitt));
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    gtk_widget_add_tick_callback(canvas, animate, NULL, NULL);
    g_timeout_add(100, update_visibility, window);
    update_visibility(window);
    gtk_main();
    return 0;
}
