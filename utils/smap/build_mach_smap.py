"""Split a daily SMAP L4 table into one soil-moisture file per MACH-US basin.

The SM entry in regions/US/MACH/region_config_MACH.m reads
    <MACH_US>/daily/timeseries/smap/smap_<gauge>.csv
with columns DATE, l4_root, l4_surf (m3/m3). SAGE needs a file for every
basin in the basin list, so basins without SMAP data get a file over the
same dates filled with -9999 (a SAGE missing value) and train on discharge
only.

Input: a daily CSV with columns gauge, Date, l4_root, l4_surf (one row per
gauge per day), e.g. daily means of the 3-hourly SPL4SMGP product extracted
at each gauge.

Usage:
    python build_mach_smap.py SMAP_DAILY_CSV BASIN_LIST MACH_US_DIR
e.g.
    python build_mach_smap.py smap_daily.csv \
        regions/US/MACH/MACH_1014_basins.txt D:/Data/MACH_US
"""
import csv
import sys
from collections import defaultdict
from pathlib import Path

MISSING = '-9999'


def main(daily, basin_list, mach_dir):
    basins = [l.strip().zfill(8) for l in Path(basin_list).read_text().splitlines()
              if l.strip()]
    rows = defaultdict(list)
    with open(daily, newline='') as f:
        for r in csv.DictReader(f):
            rows[r['gauge'].zfill(8)].append((r['Date'], r['l4_root'] or MISSING,
                                              r['l4_surf'] or MISSING))
    dates = sorted({d for v in rows.values() for d, _, _ in v})
    out = Path(mach_dir) / 'daily' / 'timeseries' / 'smap'
    out.mkdir(parents=True, exist_ok=True)
    n_data = 0
    for g in basins:
        data = sorted(rows.get(g, [])) or [(d, MISSING, MISSING) for d in dates]
        n_data += g in rows
        with open(out / f'smap_{g}.csv', 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['DATE', 'l4_root', 'l4_surf'])
            w.writerows(data)
    print(f'{len(basins)} basins: {n_data} with SMAP, {len(basins) - n_data} '
          f'filled with {MISSING}; {dates[0]}..{dates[-1]}; written to {out}')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
