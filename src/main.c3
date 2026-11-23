module dzi;
import std::math, std::core::string, std::io, std::sort, std::thread, libc;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::image;

// dzi - display ze images. One image, centered and fitted; Left/Right walk the folder (neighbours are decoded
// in the background, so switching is instant); Ctrl+S shows the folder strip at the bottom.

const int MAX_IMAGES = 8192;
const int SLOTS = 3;           // current + next + previous, each with its own decoder
const float INFO_H = 40;       // info row of the Ctrl+S bar
const float STRIP_H = 112;     // thumbnail strip below it
const float BAR_H = INFO_H + STRIP_H;
const float CELL_W = 132;
const float THUMB_W = 112;
const float THUMB_H = 74;
const int THUMBS = 64;         // cached thumbnail textures (LRU)
const int THUMB_LOADERS = 2;   // background decoders for thumbnails

struct Slot
{
	int index;                 // image index held (or being decoded); -1 = free
	image::Loader loader;
	rl::RLTexture2D tex;
	bool loaded;
	image::Status status;
	int width;
	int height;
}

struct Thumb
{
	int index;                 // -1 = empty
	rl::RLTexture2D tex;
	bool failed;
	ulong used;
}

struct ThumbLoader
{
	image::Loader loader;
	int index;                 // image being decoded; -1 = idle
}

// Copy image: PNG bytes for the clipboard, converted on a thread when the file is not a PNG.
struct Converter
{
	thread::Mutex mutex;
	thread::Thread worker;
	bool running;
	bool done;
	char[4096] path;
	char* png;
	int size;
}

// Ctrl+K dialog.
bool settings_open;
int settings_tab;
float help_scroll;
ui::Shortcut[*] help_rows = {
	{ "VIEW", "", true },
	{ "Left / Right", "Previous / next image in the folder", false },
	{ "Home / End", "First / last image", false },
	{ "Ctrl + / - / 0", "Zoom the image (0 = fit)", false },
	{ "Mouse wheel", "Zoom around the pointer", false },
	{ "Drag", "Move the zoomed image", false },
	{ "BAR", "", true },
	{ "Ctrl + S", "Info, copy buttons and thumbnails", false },
	{ "Click a thumbnail", "Show that image", false },
	{ "APP", "", true },
	{ "Ctrl + Shift + / - / 0", "Zoom the interface", false },
	{ "Ctrl + K", "This dialog", false },
	{ "q / Escape", "Quit (Escape closes this dialog first)", false },
};

// Remembered settings: $XDG_CONFIG_HOME/dzi/settings, written on exit when changed.
char[1024] config_file;
int ui_percent;                // 0 = monitor default
bool prefs_dirty;

fn void prefs_load() => @pool()
{
	String base = sys::env("XDG_CONFIG_HOME");
	if (!base.starts_with("/")) base = txt::join(sys::home(), ".config");
	txt::set(&config_file, txt::join(base, "dzi/settings"));
	String? data = sys::read_temp(txt::view(&config_file));
	if (catch data) return;
	if (data.len > 4096) return;
	foreach (line : data.tsplit("\n"))
	{
		if (line.starts_with("bar=")) bar = line == "bar=1";
		if (line.starts_with("ui_scale="))
		{
			if (try v = line[9..].to_int()) if (v == 0 || (v >= 75 && v <= 300)) ui_percent = v;
		}
	}
}

fn void prefs_save() => @pool()
{
	if (!prefs_dirty || txt::empty(&config_file)) return;
	String file = txt::view(&config_file);
	if (!sys::mkdirs(txt::dirname(file))) return;
	String tmp = txt::join(txt::dirname(file), "settings.tmp");
	if (sys::write_file(tmp, string::tformat("bar=%d\nui_scale=%d\n", bar ? 1 : 0, ui_percent))) sys::move(tmp, file);
}

fn void settings_draw() => @pool()
{
	if (!settings_open) return;
	ui::layer = 1;
	Rect box = ui::dialog(700, 560);
	if (ui::dialog_header(box, ui::I_GEAR, "dzi") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) settings_open = false;
	float x = box.x + 16;
	float w = box.width - 32;
	if (ui::button({ x, box.y + 54, w / 2 - 4, 36 }, "Shortcuts", settings_tab == 0 ? PRIMARY : NORMAL)) settings_tab = 0;
	if (ui::button({ x + w / 2 + 4, box.y + 54, w / 2 - 4, 36 }, "About", settings_tab == 1 ? PRIMARY : NORMAL)) { settings_tab = 1; collect_about(); }
	Rect area = { x, box.y + 102, w, box.height - 118 };
	if (settings_tab == 0) { help_scroll = ui::shortcut_table(area, &help_rows, help_scroll); }
	else { ui::about_draw(area); }
	ui::layer = 0;
}

fn void collect_about() => @pool()
{
	ui::about_reset("dzi", env::PROJECT_VERSION);
	ui::about_add("Settings", txt::view(&config_file));
	ui::about_add("Folder", txt::view(&folder));
	ui::about_add("Images", string::tformat("%d in this folder", count));
}

char[4096] folder;
Thumb[THUMBS] thumbs;
ThumbLoader[THUMB_LOADERS] thumb_loaders;
ulong thumb_clock;
Converter conv;
char[256] info_name;
char[600] info_detail;
int info_for = -1;             // image index the info was built for
bool info_has_size;
sys::Entry[MAX_IMAGES] images;
int count;
int cur;
Slot[SLOTS] slots;
bool bar;
float zoom = 1;                // on top of "fit"
rl::RLVector2 pan;             // image centre offset from the view centre, logical px
float strip_scroll;
bool panning;
rl::RLVector2 pan_from;

fn bool is_image(String name)
{
	return txt::iends_with(name, ".png") || txt::iends_with(name, ".jpg") || txt::iends_with(name, ".jpeg")
		|| txt::iends_with(name, ".bmp") || txt::iends_with(name, ".gif");
}

fn int by_name(sys::Entry* a, sys::Entry* b) => txt::natcmp(txt::view(&a.name), txt::view(&b.name));

<* List the folder's images once (natural order) and find `name`. *>
fn void scan(String dir, String name) => @pool()
{
	sys::Entry[] all = mem::talloc_array(sys::Entry, MAX_IMAGES);
	int n = sys::list_dir(dir, all, false);
	count = 0;
	for (int i = 0; i < n && count < MAX_IMAGES; i++)
	{
		if (!all[i].dir && is_image(txt::view(&all[i].name))) images[count++] = all[i];
	}
	sort::quicksort(images[:count], &by_name);
	cur = 0;
	for (int i = 0; i < count; i++) if (txt::view(&images[i].name) == name) { cur = i; break; }
}

fn String path_of(int i) => txt::join(txt::view(&folder), txt::view(&images[i].name));

fn int wrap(int i) => count ? (i % count + count) % count : 0;

<* Keep current, next and previous decoded; reuse slots that already hold one of them. *>
fn void want() => @pool()
{
	if (!count) return;
	int[SLOTS] wanted = { cur, wrap(cur + 1), wrap(cur - 1) };
	foreach (wi : wanted)
	{
		bool held;
		foreach (&s : slots) if (s.index == wi) held = true;
		if (held) continue;
		foreach (&s : slots)
		{
			bool needed;
			foreach (x : wanted) if (s.index == x) needed = true;
			if (needed) continue;
			if (s.loaded) { rl::unload_texture(s.tex); s.loaded = false; }
			s.index = wi;
			s.status = READY;
			s.loader.limits = { .max_edge = image::MAX_EDGE, .max_file_bytes = 128 * 1024 * 1024, .max_pixels = 64 * 1000 * 1000 };
			if (!s.loader.request(path_of(wi))) s.status = READ_ERROR;
			break;
		}
	}
}

<* Upload finished decodes (GL on the UI thread only); mipmaps keep downscaled photos smooth. *>
fn void poll()
{
	foreach (&s : slots)
	{
		image::Result r;
		if (!s.loader.take(&r)) continue;
		s.status = r.status;
		if (r.status != READY) continue;
		s.tex = rl::load_texture_from_image(r.pixels);
		rl::unload_image(r.pixels);
		rl::gen_texture_mipmaps(&s.tex);
		s.tex.set_filter(rl::RLTextureFilter.TRILINEAR);
		s.width = r.width;
		s.height = r.height;
		s.loaded = s.tex.id != 0;
	}
}

fn Slot* current()
{
	if (!count) return null;
	foreach (&s : slots) if (s.index == cur) return s;
	return null;
}

fn void show(int i) => @pool()
{
	if (!count) return;
	cur = wrap(i);
	zoom = 1;
	pan = { 0, 0 };
	want();
	info_for = -1;
	rl::set_window_title(string::tformat("%s - dzi", txt::view(&images[cur].name)).zstr_tcopy());
}

fn int main(String[] args)
{
	String target = ".";
	for (usz i = 1; i < args.len; i++)
	{
		switch (args[i])
		{
			case "--shot": case "--frames": case "--scale": i++;
			case "--help": case "-h":
				io::printn("Usage: dzi [IMAGE | FOLDER]\nLeft/Right: previous/next image in the folder; Home/End: first/last.\nCtrl+S: folder strip. Ctrl +/-/0 or wheel: zoom image (0 = fit); drag: pan. Ctrl+Shift +/-/0: interface zoom.\nq / Escape: quit.");
				return 0;
			default: target = args[i];
		}
	}
	foreach (&s : slots) s.index = -1;
	foreach (&t : thumbs) t.index = -1;
	foreach (&t : thumb_loaders) t.index = -1;
	// Folder listing and the first decode start before the window: decoding overlaps window creation.
	@pool()
	{
		char[4096] real;
		sys::realpath(&real, target);
		String p = txt::view(&real);
		if (sys::is_dir(p)) { txt::set(&folder, p); scan(p, ""); }
		else { txt::set(&folder, txt::dirname(p)); scan(txt::dirname(p), txt::basename(p)); }
	};
	want();
	prefs_load();
	defer prefs_save();
	ui::open("dzi", 1200, 800, 320, 240, (float)ui_percent / 100);
	ui::zoom_shift_only = true;
	ui::clear_color = ui::BG_HARD;
	defer ui::close();
	defer { foreach (&s : slots) { s.loader.close(); if (s.loaded) rl::unload_texture(s.tex); } }
	defer { foreach (&t : thumb_loaders) t.loader.close(); foreach (&t : thumbs) if (t.index >= 0 && t.tex.id) rl::unload_texture(t.tex); }
	defer if (conv.running) { conv.worker.join()!!; conv.mutex.destroy(); if (conv.png) rl::mem_free(conv.png); }
	ui::app_args(args);
	show(cur);
	while (ui::running()) frame();
	return 0;
}

fn void frame() => @pool()
{
	ui::frame_begin(settings_open);
	if (ui::zoom_changed) { ui_percent = (int)math::round(ui::scale * 100); prefs_dirty = true; }
	if (ui::ctrl_down() && ui::letter('k')) { settings_open = !settings_open; if (settings_open && settings_tab == 1) collect_about(); ui::top = settings_open ? 1 : 0; }
	poll();
	poll_conversion();
	float w = ui::sw();
	float h = ui::sh();
	float view_h = bar ? h - BAR_H : h;
	rl::RLVector2 mouse = rl::get_mouse_position();
	bool keys = ui::top == 0;
	if (keys && ui::ctrl_down() && ui::letter('s')) { bar = !bar; prefs_dirty = true; }
	if (keys && !ui::ctrl_down())
	{
		if (ui::repeat(rl::RLKeyboardKey.RIGHT)) show(cur + 1);
		if (ui::repeat(rl::RLKeyboardKey.LEFT)) show(cur - 1);
		if (rl::is_key_pressed(rl::RLKeyboardKey.HOME)) show(0);
		if (rl::is_key_pressed(rl::RLKeyboardKey.END)) show(count - 1);
		if (ui::letter('q') || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) ui::quit = true;
	}
	// Image zoom: Ctrl +/-/0 around the centre, the wheel around the pointer.
	float factor = 1;
	rl::RLVector2 at = { w / 2, view_h / 2 };
	if (keys && ui::ctrl_down() && !ui::shift_down())
	{
		int step = ui::zoom_step();
		if (step > 0) factor = 1.25f;
		if (step < 0) factor = 0.8f;
		if (rl::is_key_pressed(rl::RLKeyboardKey.ZERO)) { zoom = 1; pan = { 0, 0 }; }
	}
	float wheel = rl::get_mouse_wheel_move();
	if (keys && wheel != 0 && mouse[1] < view_h) { factor = wheel > 0 ? 1.15f : 1 / 1.15f; at = mouse; }
	if (factor != 1)
	{
		float nz = math::clamp(zoom * factor, 0.05f, 64.0f);
		float r = nz / zoom;
		// Keep the image point under `at` in place.
		float px = at[0] - w / 2;
		float py = at[1] - view_h / 2;
		pan = { px - (px - pan[0]) * r, py - (py - pan[1]) * r };
		zoom = nz;
	}
	// Drag to pan.
	if (keys && rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) && mouse[1] < view_h) { panning = true; pan_from = mouse; }
	if (!rl::is_mouse_button_down(rl::RLMouseButton.LEFT)) panning = false;
	if (panning)
	{
		pan = { pan[0] + mouse[0] - pan_from[0], pan[1] + mouse[1] - pan_from[1] };
		pan_from = mouse;
	}

	Slot* s = current();
	if (!count)
	{
		ui::text("No images here (PNG, JPEG, BMP, GIF)", 24, 24, 18, ui::GRAY);
	}
	else if (s && s.loaded)
	{
		// Fit inside the view without enlarging past 1 texel = 1 physical pixel, then the user zoom.
		float sc = ui::scale;
		float fit = math::min(1.0f, math::min(w * sc / (float)s.tex.width, view_h * sc / (float)s.tex.height));
		float dw = (float)s.tex.width * fit * zoom / sc;
		float dh = (float)s.tex.height * fit * zoom / sc;
		Rect dst = { w / 2 + pan[0] - dw / 2, view_h / 2 + pan[1] - dh / 2, dw, dh };
		rl::draw_texture_pro(s.tex, { 0, 0, (float)s.tex.width, (float)s.tex.height }, dst, { 0, 0 }, 0, rl::WHITE);
	}
	else if (s && s.status != READY)
	{
		String why = s.status == TOO_LARGE ? "too large" : s.status == INVALID_IMAGE ? "not a readable image" : s.status == NO_MEMORY ? "out of memory" : "cannot be read";
		ui::text_fit(string::tformat("%s: %s", txt::view(&images[cur].name), why), 24, 24, w - 48, 16, ui::RED);
	}
	if (bar && count) draw_strip(w, h);
	settings_draw();
	ui::frame_end();
}

fn String home_short(String p)
{
	String home = sys::home();
	if (home.len > 1 && p.starts_with(home) && (p.len == home.len || p[home.len] == '/')) return string::tformat("~%s", p[home.len..]);
	return p;
}

fn void size_text(char[] out, long b) => @pool()
{
	if (b < 1000) { txt::set(out, string::tformat("%d B", b)); return; }
	double v = (double)b;
	String[4] units = { "kB", "MB", "GB", "TB" };
	int u = -1;
	while (v >= 1000 && u < 3) { v /= 1000; u++; }
	txt::set(out, v < 10 ? string::tformat("%.1f %s", v, units[u]) : string::tformat("%d %s", (int)(v + 0.5), units[u]));
}

<* Info for the current image: one lstat when the image changes, rebuilt once its pixel size is known. *>
fn void update_info() => @pool()
{
	Slot* s = current();
	bool sized = s && s.loaded;
	if (info_for == cur && info_has_size == sized) return;
	info_for = cur;
	info_has_size = sized;
	String name = txt::view(&images[cur].name);
	txt::set(&info_name, name);
	sz? dot = name.rindex_of_char('.');
	char[8] fmt;
	if (try dot) { foreach (i, c : name[(usz)dot + 1..]) if (i < 7) fmt[i] = c >= 'a' && c <= 'z' ? c - 32 : c; }
	String detail = sized ? string::tformat("%d × %d · %s", s.width, s.height, (ZString)&fmt) : string::tformat("%s", (ZString)&fmt);
	libc::Stat st;
	if (libc::stat(path_of(cur).zstr_tcopy(), &st) == 0)
	{
		char[32] size;
		size_text(&size, st.st_size);
		char[32] when;
		libc::Tm tm;
		Time_t mt = st.st_mtime;
		libc::localtime_r(&mt, &tm);
		libc::strftime(&when, when.len, "%Y-%m-%d %H:%M", &tm);
		detail = string::tformat("%s · %s · modified %s", detail, txt::view(&size), (ZString)&when);
	}
	txt::set(&info_detail, string::tformat("%s · %s", detail, home_short(txt::view(&folder))));
}

<* Pixels only: with file URIs as well, Chromium/Electron apps (e.g. Flatpak Mattermost) prefer the file, which their
   sandbox cannot read, and paste an empty attachment. Copy path covers the path. *>
fn void set_image_clipboard(char[] png)
{
	String[1] mimes = { "image/png" };
	char[][1] datas = { png };
	if (ui::clipboard_set_data(&mimes, &datas)) { ui::toast("Image copied"); }
	else { ui::toast("Could not copy the image", ui::RED); }
}

fn int convert(void* arg)
{
	Converter* c = arg;
	rl::RLImage img = rl::load_image((ZString)&c.path);
	char* png;
	int size;
	if (img.data)
	{
		png = rl::export_image_to_memory(img, ".png", &size);
		rl::unload_image(img);
	}
	c.mutex.lock();
	c.png = png;
	c.size = png ? size : 0;
	c.done = true;
	c.mutex.unlock();
	return 0;
}

<* Copy image: PNG files go to the clipboard as they are; other formats are converted to PNG on a thread. *>
fn void copy_image() => @pool()
{
	if (!count) return;
	String path = path_of(cur);
	if (txt::iends_with(path, ".png"))
	{
		char[]? bytes = file::load_temp(path);
		if (catch bytes) { ui::toast("Cannot read the image", ui::RED); return; }
		set_image_clipboard(bytes);
		return;
	}
	if (conv.running) { ui::toast("Still preparing the previous copy", ui::YELLOW); return; }
	if (catch conv.mutex.init()) return;
	txt::set(&conv.path, path);
	conv.done = false;
	conv.png = null;
	if (catch conv.worker.create(&convert, &conv)) { conv.mutex.destroy(); ui::toast("Could not copy the image", ui::RED); return; }
	conv.running = true;
	ui::toast("Preparing image for the clipboard…");
}

fn void poll_conversion()
{
	if (!conv.running) return;
	conv.mutex.lock();
	bool done = conv.done;
	conv.mutex.unlock();
	if (!done) return;
	conv.worker.join()!!;
	conv.mutex.destroy();
	conv.running = false;
	if (conv.png) { set_image_clipboard(conv.png[:conv.size]); rl::mem_free(conv.png); conv.png = null; }
	else { ui::toast("Could not convert the image", ui::RED); }
}

fn void copy_path() => @pool()
{
	if (!count) return;
	rl::set_clipboard_text(path_of(cur).zstr_tcopy());
	ui::toast("Path copied");
}

fn Thumb* thumb_of(int index)
{
	foreach (&t : thumbs) if (t.index == index) return t;
	return null;
}

<* Thumbnails for the visible strip cells: two background decoders, nearest to the current image first; an LRU of
   THUMBS textures. Nothing is requested while the strip is hidden. *>
fn void update_thumbs(int first, int end) => @pool()
{
	foreach (&tl : thumb_loaders)
	{
		image::Result r;
		if (tl.index < 0 || !tl.loader.take(&r)) continue;
		// Least recently used slot that is not on screen.
		Thumb* slot = &thumbs[0];
		foreach (&t : thumbs)
		{
			if (t.index < 0) { slot = t; break; }
			if (t.used < slot.used) slot = t;
		}
		if (slot.index >= 0 && slot.tex.id) rl::unload_texture(slot.tex);
		*slot = { .index = tl.index, .used = ++thumb_clock };
		if (r.status == READY)
		{
			slot.tex = rl::load_texture_from_image(r.pixels);
			rl::unload_image(r.pixels);
			slot.tex.set_filter(rl::RLTextureFilter.BILINEAR);
		}
		else { slot.failed = true; }
		tl.index = -1;
	}
	foreach (&tl : thumb_loaders)
	{
		if (tl.index >= 0) continue;
		// Nearest visible image without a thumbnail (the loaded slots draw their own texture).
		int best = -1;
		int best_d = 0x7fffffff;
		for (int i = first; i < end; i++)
		{
			if (thumb_of(i)) continue;
			bool busy;
			foreach (&o : thumb_loaders) if (o.index == i) busy = true;
			foreach (&sl : slots) if (sl.index == i && sl.loaded) busy = true;
			if (busy) continue;
			int d = math::abs(i - cur);
			if (d < best_d) { best = i; best_d = d; }
		}
		if (best < 0) break;
		tl.loader.limits = { .max_edge = (int)(THUMB_W * ui::scale), .max_file_bytes = 128 * 1024 * 1024, .max_pixels = 64 * 1000 * 1000 };
		if (tl.loader.request(path_of(best))) tl.index = best;
	}
}

fn void draw_fitted(rl::RLTexture2D tex, Rect box)
{
	float k = math::min(box.width / (float)tex.width, box.height / (float)tex.height);
	float w = (float)tex.width * k;
	float h = (float)tex.height * k;
	rl::draw_texture_pro(tex, { 0, 0, (float)tex.width, (float)tex.height }, { box.x + (box.width - w) / 2, box.y + (box.height - h) / 2, w, h }, { 0, 0 }, 0, rl::WHITE);
}

<* Ctrl+S bar: info row with copy buttons, then the thumbnail strip (only visible cells are drawn or loaded). *>
fn void draw_strip(float w, float h) => @pool()
{
	float top = h - BAR_H;
	ui::panel({ 0, top, w, BAR_H }, ui::BG);
	ui::hline(0, top, w, ui::BG2);
	update_info();
	// Info row.
	float bx = w - 16 - 130 - 8 - 150;
	float name_w = math::min(ui::text_w(txt::view(&info_name), 15), (bx - 40) * 0.4f);
	ui::text_fit(txt::view(&info_name), 16, top + 12, name_w, 15, ui::FG);
	ui::text_fit(txt::view(&info_detail), 16 + name_w + 14, top + 13, math::max(0.0f, bx - name_w - 46), 14, ui::FG4);
	if (ui::button({ bx, top + 6, 150, 30 }, "Copy image", NORMAL, ui::I_COPY)) copy_image();
	if (ui::button({ w - 16 - 130, top + 6, 130, 30 }, "Copy path", NORMAL, ui::I_LINK)) copy_path();
	// Strip.
	float sy = top + INFO_H;
	float content = (float)count * CELL_W;
	float cx = (float)cur * CELL_W;
	if (cx < strip_scroll) strip_scroll = cx;
	if (cx + CELL_W > strip_scroll + w) strip_scroll = cx + CELL_W - w;
	strip_scroll = math::clamp(strip_scroll, 0.0f, math::max(0.0f, content - w));
	int first = (int)(strip_scroll / CELL_W);
	int end = math::min(count, first + (int)(w / CELL_W) + 2);
	update_thumbs(first, end);
	for (int i = first; i < end; i++)
	{
		Rect cell = { (float)i * CELL_W - strip_scroll + 6, sy + 4, CELL_W - 12, STRIP_H - 10 };
		if (i == cur) { ui::panel(cell, ui::BG2, 4); }
		else if (ui::hover(cell)) { ui::panel(cell, ui::BG1, 4); }
		Rect pic = { cell.x + (cell.width - THUMB_W) / 2, cell.y + 4, THUMB_W, THUMB_H };
		Slot* full;
		foreach (&sl : slots) if (sl.index == i && sl.loaded) full = sl;
		Thumb* t = thumb_of(i);
		if (full) { draw_fitted(full.tex, pic); }
		else if (t && t.tex.id) { t.used = ++thumb_clock; draw_fitted(t.tex, pic); }
		else { ui::text(ui::I_IMAGE, pic.x + pic.width / 2 - 10, pic.y + pic.height / 2 - 10, 20, t && t.failed ? ui::DIM_RED : ui::BG3); }
		ui::text_fit(txt::view(&images[i].name), cell.x + 6, cell.y + THUMB_H + 10, cell.width - 12, 13, i == cur ? ui::FG : ui::FG4);
		if (ui::clicked(cell)) show(i);
	}
	Slot* s = current();
	String pos = string::tformat("%d / %d", cur + 1, count);
	float pw = ui::text_w(pos, 13) + 16;
	ui::panel({ w - pw - 8, top - 26, pw, 22 }, ui::BG, 4);
	ui::text(pos, w - pw, top - 22, 13, ui::FG4);
}
