<p align="center">
  <img src="assets/dzi.svg" width="112" alt="dzi icon">
</p>

<h1 align="center">dzi</h1>
<p align="center"><b>display ze images</b> · a minimal, fast image viewer for Wayland</p>

<p align="center">
  <img src="docs/screenshot.png" width="720" alt="dzi showing a landscape with the thumbnail strip">
</p>

Open an image and flip through its folder with the arrow keys: the next and previous images are decoded ahead, so
switching is instant. Zoom and pan, show a thumbnail strip, copy the image or its path. PNG, JPEG, BMP and GIF.

**Press `Ctrl + K`** for all keyboard shortcuts and the About page.

## Requirements to run

- Linux x86_64 with a **Wayland** session (no X11 / XWayland)
- OpenGL 3.3 graphics driver (Mesa or your GPU vendor's)
- `libwayland-client`, `libwayland-cursor`, `libwayland-egl`, `libxkbcommon`, `libEGL`: already present on any Wayland desktop

## Requirements to build

- [C3](https://c3-lang.org) compiler `c3c` **0.8.x**
- a C compiler for linking (`gcc` or `clang`)
- `git`, `python3`

raylib and the UI font come with the [bmu](https://github.com/foelkdavid/bmu) submodule; nothing else to install.

## Download, build, install

```sh
git clone --recurse-submodules https://github.com/foelkdavid/dzi.git
cd dzi
c3c build install --trust=full
```

This installs `~/.local/bin/dzi`, a desktop launcher ("Open with" for images) and the icon (no sudo). Make sure
`~/.local/bin` is on your `PATH`, then run `dzi photo.jpg` or `dzi some/folder`.

```sh
git pull --recurse-submodules && c3c build install --trust=full   # update
c3c build uninstall --trust=full                                   # uninstall
```

## Licenses

The embedded UI font is SIL OFL 1.1 and raylib is zlib-licensed; their notices are in [`licenses/`](licenses/) and are
installed with the app.
