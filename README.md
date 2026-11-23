# dzi — display ze images

A minimal, fast image viewer for Wayland, built on [bmu](https://github.com/foelkdavid/bmu) (C3 + raylib).

```sh
dzi photo.jpg          # or: dzi some/folder
```

| Key | Action |
|---|---|
| Left / Right | previous / next image in the folder (wraps) |
| Home / End | first / last image |
| Ctrl + / - / 0, mouse wheel | zoom the image (0 = fit); drag to pan |
| Ctrl + Shift + / - / 0 | zoom the interface |
| Ctrl + S | show / hide the bottom bar: image info, Copy image / Copy path, thumbnail strip |
| q / Escape | quit |

PNG, JPEG, BMP and GIF (first frame). Images are decoded at full resolution on background threads; the next and
previous images are decoded ahead, so switching is instant. Thumbnails are decoded in the background only for
the strip cells on screen (64 kept). Copy image puts PNG data (converted on a thread for other formats) and the
file URI on the clipboard; on Wayland it stays available while dzi runs (or via a clipboard manager). Images fit the window but are never enlarged past
their real pixel size until you zoom. Limits: 16384 px edge, 64 megapixels, 128 MiB files, 8192 images per folder.

## Build and install

Needs `c3c` 0.8.x and a Wayland session.

```sh
git clone --recurse-submodules git@github.com:foelkdavid/dzi.git
cd dzi && c3c build install --trust=full     # ~/.local/bin/dzi + desktop launcher ("Open with" for images)
git pull --recurse-submodules && c3c build install --trust=full    # update
c3c build uninstall --trust=full
```

The embedded UI font is OFL 1.1 and raylib is zlib-licensed; their notices are in `licenses/` and are installed
with the binary.
