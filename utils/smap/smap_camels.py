#!/usr/bin/env python3
"""Download SMAP L4 soil moisture at CAMELS-US gauges as daily means for SAGE.

Reads the 3-hourly SPL4SMGP granules from NASA Earthdata, samples the native
9 km EASE-Grid 2.0 cell that contains each gauge, and averages each UTC day.
The result, smap_daily.csv, has the columns gauge, Date, l4_root, l4_surf and
n_obs (the number of 3-hourly root-zone values in the daily mean), which is
the format prep_smap reads.

Each day is saved to days/<date>.csv as soon as it is done, so a run that is
interrupted resumes where it stopped when started again.

The gauges default to camels_us_671.csv next to this script: all 671
CAMELS-US gauges, taken from camels_topo.txt (Zenodo record 15529996).

Requires earthaccess, h5py, numpy and pyproj, and a free NASA Earthdata
account (https://urs.earthdata.nasa.gov). See authenticate() for the ways
to supply it. smap_camels.ipynb runs the same steps interactively.

Example, from a terminal:
    python smap_camels.py --start 2015-04-01 --end 2019-03-31
"""
import argparse
from contextlib import closing
import csv
from datetime import date, datetime, timedelta
from pathlib import Path
import re
import time

import earthaccess
import h5py
import numpy as np
from pyproj import Transformer

LAYERS = {'l4_root': 'sm_rootzone', 'l4_surf': 'sm_surface'}
FIELDS = ['gauge', 'Date', 'l4_root', 'l4_surf', 'n_obs']
GAUGES = Path(__file__).resolve().parent / 'camels_us_671.csv'
OUTPUT = Path(__file__).resolve().parents[2] / 'Data' / 'SMAP'
TO_EASE2 = Transformer.from_crs('EPSG:4326', 'EPSG:6933', always_xy=True)
LOGIN_HELP = ('Set EARTHDATA_USERNAME and EARTHDATA_PASSWORD, add '
              'urs.earthdata.nasa.gov to ~/.netrc, or run from a terminal or '
              'the notebook to be prompted. Accounts are free at '
              'https://urs.earthdata.nasa.gov.')
_logged_in = False


def authenticate(strategy='all'):
    """Log in to NASA Earthdata. With strategy 'all', earthaccess tries, in order:
      1. the EARTHDATA_TOKEN, or EARTHDATA_USERNAME and EARTHDATA_PASSWORD,
         environment variables
      2. ~/.netrc (_netrc on Windows) with the line
         machine urs.earthdata.nasa.gov login <user> password <password>
      3. a username and password prompt
    'interactive' always prompts. Credentials are not saved."""
    global _logged_in
    try:
        auth = earthaccess.login(strategy=strategy, persist=False)
    except EOFError:
        # the prompt was reached but nothing can type into it, e.g. the
        # VS Code Run button or an output panel instead of a terminal
        raise RuntimeError('No saved Earthdata login was found and there is '
                           'no terminal to type one into. ' + LOGIN_HELP) from None
    if not auth.authenticated:
        raise RuntimeError('NASA Earthdata login failed. ' + LOGIN_HELP)
    _logged_in = True
    print('Logged in to NASA Earthdata.')


def load_gauges(path):
    """Gauge ids and coordinates from camels_topo.txt, or a CSV with the
    columns gauge_id, latitude, longitude."""
    with open(path, newline='') as f:
        delim = ';' if ';' in f.readline() else ','
        f.seek(0)
        rows = list(csv.DictReader(f, delimiter=delim))
    lat = 'gauge_lat' if 'gauge_lat' in rows[0] else 'latitude'
    lon = 'gauge_lon' if 'gauge_lon' in rows[0] else 'longitude'
    ids = [r['gauge_id'].strip().zfill(8) for r in rows]
    return (ids, np.array([float(r[lat]) for r in rows]),
            np.array([float(r[lon]) for r in rows]))


def cells(hdf, lat, lon):
    """Row and column of the EASE-Grid 2.0 cell containing each point."""
    x, y = TO_EASE2.transform(lon, lat)
    index = []
    for axis, p in ((hdf['y'][:], y), (hdf['x'][:], x)):
        i = np.floor((np.asarray(p) - axis[0]) / (axis[1] - axis[0]) + 0.5).astype(int)
        if np.any(i < 0) or np.any(i >= len(axis)):
            raise ValueError('a gauge lies outside the SMAP grid')
        index.append(i)
    return index


def sample(ds, rows, cols):
    """Values at (rows, cols); fill and out-of-range values become NaN."""
    r0, c0 = rows.min(), cols.min()
    block = ds[r0:rows.max() + 1, c0:cols.max() + 1]      # one read per layer
    v = block[rows - r0, cols - c0].astype(float)
    v = v * float(np.ravel(ds.attrs.get('scale_factor', 1))[0]) \
          + float(np.ravel(ds.attrs.get('add_offset', 0))[0])
    v[~((v >= 0) & (v <= 1))] = np.nan                   # -9999 fill included
    return v


def stamp(name):
    return datetime.strptime(
        re.search(r'SMAP_L4_SM_gph_(\d{8}T\d{6})_', name)[1], '%Y%m%dT%H%M%S')


def granules(day, version):
    """The day's 3-hourly granules; the newest file wins when a time repeats."""
    for attempt in range(5):
        try:
            found = earthaccess.search_data(
                short_name='SPL4SMGP', version=version, count=-1,
                temporal=(f'{day}T00:00:00Z', f'{day}T23:59:59Z'))
            break
        except (RuntimeError, OSError):
            if attempt == 4:
                raise
            time.sleep(30 * (attempt + 1))
    best = {}
    for g in found:
        name = g['umm']['GranuleUR']
        t = stamp(name)
        if t.date() == day and (t not in best or name > best[t]['umm']['GranuleUR']):
            best[t] = g
    return [best[t] for t in sorted(best)]


def read(g, lat, lon):
    """Stream one granule and sample both layers at every gauge."""
    for attempt in range(3):
        try:
            remote = earthaccess.open([g], show_progress=False)[0]
            with closing(remote), h5py.File(remote, 'r') as hdf:
                rows, cols = cells(hdf, lat, lon)
                return {k: sample(hdf['Geophysical_Data'][layer], rows, cols)
                        for k, layer in LAYERS.items()}
        except (TypeError, ValueError, KeyError):
            raise                                        # not a network problem
        except Exception:
            if attempt == 2:
                raise
            time.sleep(5 * (attempt + 1))


def write_day(path, day, ids, values):
    """Daily means over the granules, written atomically."""
    means, counts = {}, {}
    for k in LAYERS:
        a = np.vstack([v[k] for v in values])          # granules x gauges
        ok = np.isfinite(a)
        counts[k] = ok.sum(axis=0)
        means[k] = np.where(ok, a, 0).sum(axis=0) / np.maximum(counts[k], 1)
        means[k][counts[k] == 0] = np.nan
    fmt = lambda v: '' if np.isnan(v) else f'{v:.6g}'
    tmp = path.with_suffix('.tmp')
    with open(tmp, 'w', newline='') as f:
        w = csv.writer(f)
        for i, g in enumerate(ids):
            w.writerow([g, day, fmt(means['l4_root'][i]), fmt(means['l4_surf'][i]),
                        counts['l4_root'][i]])
    tmp.replace(path)


def download(start, end, gauges=GAUGES, output=OUTPUT, version='008'):
    """Download start..end (inclusive UTC days, 'YYYY-MM-DD') for the gauges
    and write output/smap_daily.csv. Days already in output/days are skipped.
    Returns the path of smap_daily.csv."""
    start, end = date.fromisoformat(str(start)), date.fromisoformat(str(end))
    output = Path(output)
    ids, lat, lon = load_gauges(gauges)
    days_dir = output / 'days'
    days_dir.mkdir(parents=True, exist_ok=True)
    print(f'{len(ids)} gauges, {start} to {end}, output {output}')
    if not _logged_in:
        authenticate()

    day = start
    while day <= end:
        path = days_dir / f'{day}.csv'
        if not path.exists():
            gs = granules(day, version)
            if not gs:
                print(f'{day}: no granules published, skipped')
            else:
                t = time.perf_counter()
                write_day(path, day, ids, [read(g, lat, lon) for g in gs])
                note = '' if len(gs) == 8 else '  (incomplete day)'
                print(f'{day}: {len(gs)} granules in {time.perf_counter() - t:.0f}s{note}')
        day += timedelta(days=1)

    out = output / 'smap_daily.csv'
    tmp = out.with_suffix('.tmp')
    with open(tmp, 'w', newline='') as f:
        f.write(','.join(FIELDS) + '\n')
        day = start
        while day <= end:
            path = days_dir / f'{day}.csv'
            if path.exists():
                f.write(path.read_text())
            day += timedelta(days=1)
    tmp.replace(out)
    print(f'wrote {out}')
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--gauges', type=Path, default=GAUGES,
                   help='camels_topo.txt, or a CSV with gauge_id, latitude, '
                        'longitude (default: camels_us_671.csv)')
    p.add_argument('--start', required=True, type=date.fromisoformat,
                   help='first UTC day, YYYY-MM-DD (SMAP L4 starts 2015-03-31)')
    p.add_argument('--end', required=True, type=date.fromisoformat,
                   help='last UTC day, YYYY-MM-DD')
    p.add_argument('--output', type=Path, default=OUTPUT,
                   help='folder for days/ and smap_daily.csv (default: Data/SMAP)')
    p.add_argument('--version', default='008', help='SPL4SMGP product version')
    a = p.parse_args()
    try:
        download(a.start, a.end, a.gauges, a.output, a.version)
    except RuntimeError as err:
        raise SystemExit(str(err)) from None


if __name__ == '__main__':
    main()
