# laddstolpar-databricks

Slutprojekt (DE25) — David Färm. Data engineering pipeline for EV charging
station ("laddstolpar") analysis, using Trafikverket's open traffic API as a
signal source, headed toward an Azure Databricks pipeline.

## Setup

```
python -m venv .venv
.venv\Scripts\activate      # PowerShell: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env      # then fill in TRV_API_KEY
```

## Scripts

- `trafficflow_peak_probe.py` — local, time-boxed probe of Trafikverket's
  `TrafficFlow` object during weekday peak hour. Run locally (not in Azure)
  to avoid compute cost while validating the API shape.

  ```
  python trafficflow_peak_probe.py                 # 3 snapshots, 5 min apart
  python trafficflow_peak_probe.py --snapshots 1    # single snapshot
  ```
