# Mandelbrot Explorer

Interactive Mandelbrot set viewer with zooming, panning, and dynamically adaptive colormap.

## Features

- GPU-like speed via `numba` and CPU parallel loops (`njit(parallel=True)`).
- Pan with left mouse drag.
- Zoom with mouse wheel.
- Automatically increases iteration limit as zoom deepens.
- Slider for max iterations and reset button.
- Runtime colormap adjustment for sharp edges with iteration depth.

## Install

```bash
python -m pip install -r requirements.txt
```

## Run

```bash
python mandelbrot_app.py
```

## Notes

- On first run numba will compile; this may take a few seconds.
- For best interactivity, run on at least 4 physical cores.
