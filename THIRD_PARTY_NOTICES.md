# Third-party notices

Omakvm bundles no third-party program. It installs and drives the ones below,
which keep their own licenses.

## Lan Mouse

Keyboard and mouse sharing is done by
[Lan Mouse](https://github.com/feschber/lan-mouse) by Ferdinand Schober and
contributors, licensed under GPL-3.0-or-later. Omakvm installs it from the
distribution's own package repository and runs it as a separate program; no
Lan Mouse code is part of this repository.

## wl-clipboard

The clipboard relay reads and writes the clipboard through `wl-paste` and
`wl-copy` from [wl-clipboard](https://github.com/bugaevc/wl-clipboard),
licensed under GPL-3.0-or-later. It ships with Omarchy and is run as a
separate program.

## Omarchy Lan Mouse

The way `BarWidget.qml` hosts its panel, and the layout of the state rows in
`Panel.qml`, follow
[omarchy-lan-mouse](https://github.com/mdelgert/omarchy-lan-mouse) by Matthew
Elgert, which is licensed as follows:

> MIT License
>
> Copyright (c) 2026 Matthew Elgert
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## Omarchy

Omakvm is an independent community project. It is not an official Omarchy
plugin and is not endorsed by Omarchy or 37signals.
