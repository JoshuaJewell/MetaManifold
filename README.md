# MetaManifold

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Julia ≥ 1.0](https://img.shields.io/badge/Julia-%E2%89%A51.0-9558B2?logo=julia)](https://julialang.org)
[![R ≥ 4.0](https://img.shields.io/badge/R-%E2%89%A54.0-276DC3?logo=r)](https://www.r-project.org)
[![CI](https://github.com/JoshuaJewell/MetaManifold/actions/workflows/ci.yml/badge.svg)](https://github.com/JoshuaJewell/MetaManifold/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/JoshuaJewell/MetaManifold-WebUI/graph/badge.svg?token=20F1VLF590)](https://codecov.io/gh/JoshuaJewell/MetaManifold-WebUI)

MetaManifold wraps standard amplicon sequencing workflows into a single configurable Julia orchestrator: from raw paired-end Next Generation Sequencing reads through denoising, taxonomy assignment, and taxonomic filtering, with interactive analysis in the browser.

## Overview

MetaManifold consists of a Julia backend (pipeline engine + REST API) and a TypeScript/React frontend. The pipeline runs FastQC, MultiQC, cutadapt, DADA2, SWARM, vsearch, and cd-hit under the hood; results are stored in per-run DuckDB databases and served to the frontend as interactive Plotly charts.

**Pipeline stages**

```
Raw FASTQs  (data/{study}/[{group}/]{run}/*.fastq.gz)
      │
   cutadapt, primer trimming
      │
      ├────────────────────────────┐
      │                            │
   DADA2*, ASV;               SWARM*, OTU;
   filter & trim              merge pairs
   learn error rates          dereplicate
   denoise + merge            chimera filter
   length filter              cluster OTUs
   chimera removal                 │
   taxonomy assign*                │
      │                            │
   cd-hit-est*, demultiplex        │
      │                            │
   vsearch*                   vsearch, global alignment
      │                            │
      ├────────────────────────────┘
      │
   merge_taxa;
   join ASV tables*
   join counts-taxonomy
   apply filters
      │
   DuckDB results store
```
*optional

**Analysis**

Once a run completes, analysis is performed on request through the web UI:

- Alpha diversity (richness, Shannon, Simpson) per sample
- Taxonomic composition bar charts (relative or absolute)
- Pipeline stage read-count summaries
- Cross-run alpha diversity comparison (boxplots)
- NMDS ordination (Bray-Curtis, via R/vegan)
- PERMANOVA (via R/vegan)

All analysis charts are returned as Plotly JSON and rendered interactively in the browser.

## Prerequisites

- **Julia** >= 1.0 (installed automatically by `install.sh` if missing)
- **R** >= 4.0 (required for the DADA2 stage and NMDS/PERMANOVA analysis)
  - Ubuntu/Debian: `sudo apt install r-base`
  - macOS: `brew install r` or [CRAN package](https://cran.r-project.org/bin/macosx/)
- **bun** or **Node.js** for building the frontend (bun preferred)

## Installation

```bash
git clone https://github.com/JoshuaJewell/MetaManifold.git
cd MetaManifold
bash install.sh
```

`install.sh` will check for Julia and R, install Julia and R dependencies, locate or download each external tool (cutadapt, FastQC, MultiQC, vsearch, cd-hit-est). Tool paths can be configured manually in `config/tools.yml`, including by SSH if you wish to use a server-hosted binary.

To update:
```bash
bash install.sh --update
```

### Reproducing the R environment

The R-side dependencies (DADA2, vegan, and their transitive packages) are
pinned with [`renv`](https://rstudio.github.io/renv/). The lockfile lives at
`renv.lock` and a project-local library is created on first activation.

```bash
Rscript -e 'if (!requireNamespace("renv", quietly=TRUE)) install.packages("renv", repos="https://cloud.r-project.org"); renv::restore(prompt = FALSE)'
```

Subsequent invocations of `Rscript` or `R` from the repository root will pick
up the project library automatically via the committed `.Rprofile`. To add or
upgrade a package, install it inside the project (`renv::install(...)`) and
record the change with `renv::snapshot()`.

### Tool paths

`install.sh` generates `config/tools.yml`. You can edit it manually, for example, to point a tool at a remote server:

```yaml
vsearch:
  path: "user@bioserver:/home/user/software/vsearch"
```

When a remote SSH path is set, the pipeline routes that tool's invocations through
`ssh`. `config/defaults/tools.yml` contains the full config format.

## Quick start

### 1. Place paired-end FASTQs under data/
Put `.fastq.gz` files into `data/MyProject/run_A`. 

### 2. Start the server (builds frontend on first run)
`bash start.sh`

### 3. Open http://localhost:8080

The web UI lets you create studies, configure pipeline parameters, launch runs, and explore results interactively. All state lives in the filesystem under `data/` and `projects/`.

| Environment variable      | Default           | Description   |
| ------------------------- | ----------------- | ------------- |
| `JULIA_METAMANIFOLD_PORT` | `8080`            | Server port   |
| `JULIA_METAMANIFOLD_ROOT` | working directory | Project root  |
| `JULIA_THREADS`           | `8`               | Julia threads |

Or run the Julia server directly:

```bash
julia --project=. src/server/server.jl
```

## Configuration

Pipeline settings use a cascade: each level overrides the one above it, and any key you omit is inherited from the nearest ancestor. The fully merged result is written to `run_config.yml` at runtime; that is the single place to see exactly what was used for a run.

Settings can be edited in the web UI (per-study, per-group, or per-run) or as YAML files directly.

| File | Purpose |
|------|---------|
| `config/defaults/` | Canonical defaults for every setting; do not edit |
| `config/filters/` | Directory of taxonomic filter configs |
| `config/databases.yml` | Database URIs and optional local paths |
| `config/primers.yml` | Primer sequences and pair definitions |
| `config/tools.yml` | Tool binary paths (cutadapt, FastQC, MultiQC, vsearch, cd-hit-est) |
| `config/pipeline.yml` | Machine-level overrides (lowest user-editable precedence) |
| `data/{name}/pipeline.yml` | Study-level overrides |
| `data/{name}/{group}/pipeline.yml` | Group-level overrides (intermediate directories) |
| `data/{name}/{run}/pipeline.yml` | Run-level overrides (highest precedence) |
| `projects/{name}/{run}/run_config.yml` | Generated merged config (provenance); do not edit |

Each `pipeline.yml` stub is created with a comment block explaining that level's role. Write only the keys you want to change; omit the rest.

### Configuring databases (`config/databases.yml`)

This is the single place to manage DB URIs shared across all projects.

```yaml
databases:
  dir: "./databases"
  pr2:
    dada2:
      uri: "https://..."       # DADA2-format FASTA (downloaded on first use)
      local: ~                 # set to a local path to skip download
    vsearch:
      uri: "https://..."       # vsearch-format FASTA
      local: ~
```

### Defining primer pairs `primers.yml`

Maps primer names to sequences and defines which forward/reverse sequences constitute a pair:

```yaml
Forward:
  PrimerF: "CCAGCASCYGCGGTAATTCC"

Reverse:
  Primer1R: "ACTTTCGTTCTTGATYRA"
  Primer2R: "DCTKTCGTYCTTGATYRA"

Pairs:
  - PrimerPair1:
      - PrimerF
      - Primer1R
  - PrimerPair2:
      - PrimerF
      - Primer2R
```

Store all primer pairs in here and reference whichever combinations you need per project. Shared primers across pairs (same forward primer in two pairs) are automatically deduplicated in the `cutadapt` invocation since otherwise it complains a bit. If you need duplicates, you must create the same sequence under a different name.

### Configuring cutadapt (`cutadapt:` in `pipeline.yml`)

Selects which primer pairs to apply and controls trimming behaviour.

```yaml
cutadapt:
  # Names must match keys in the Pairs section of config/primers.yml.
  primer_pairs:
    - PrimerPair1
    - PrimerPair2
  min_length: 200           # discard reads shorter than this after trimming (-m)
  discard_untrimmed: true   # drop reads where no adapter was found (--discard-untrimmed)
  cores: 0                  # parallel cores; 0 = auto-detect (-j)
  quality_cutoff: ~         # 3' quality trimming cutoff, null to disable (-q)
  error_rate: ~             # max adapter mismatch rate, null = cutadapt default (-e)
  overlap: ~                # min adapter overlap length, null = cutadapt default (-O)
  optional_args: ""         # additional flags passed verbatim to cutadapt
```

### Configuring DADA2 (`dada2:` in `pipeline.yml`)

```yaml
dada2:
  file_patterns:
    mode: "paired"               # paired | forward | reverse

  # Filter and trim; DADA2's filterAndTrim():
  filter_trim:
    trunc_q: 2
    trunc_len: [220, 220]        # [forward, reverse]; first value used for single-end mode
    max_ee: [3, 3]               # maximum expected errors in F and R reads
    min_len: 175
    max_n: 0
    match_ids: true
    rm_phix: true

  # Denoising; learnErrors() and dada():
  dada:
    seed: 123
    nbases: 200000000
    max_consist: 15
    pool_method: "pseudo"        # none | pseudo | true

  # Merging; mergePairs(), paired mode only:
  merge:
    min_overlap: 20
    max_mismatch: 0
    trim_overhang: true

  # ASV length filtering and chimera removal:
  asv:
    band_size_min: 200           # null to skip length filtering
    band_size_max: 430
    denovo_method: "consensus"   # consensus | pooled | per-sample

  # Taxonomy; assignTaxonomy() against the configured database:
  taxonomy:
    database: pr2                # key into config/databases.yml
    multithread: 4               # threads for assignTaxonomy(); higher values increase memory use
    min_boot: 0                  # minimum bootstrap confidence to retain (0-100)
    # Taxonomy rank names are read from databases.yml (the `levels:` key under
    # each database entry). Do not set them here.

    # Optional: offload the memory-intensive assignTaxonomy() step to a remote
    # server via SSH. Omit or set host to null to run locally.
    # DISCLAIMER: You are solely responsible for ensuring you have authorisation
    # to use the configured host. See config/defaults/pipeline.yml for the full disclaimer.
    remote:
      host: ~                    # user@hostname
      identity_file: ~           # path to SSH private key; null to use password auth
      rscript: "Rscript"         # path to Rscript on the server
      staging_dir: "/absolute/path/on/server"
      # To avoid transferring the database each run, set dada2.remote_path under
      # the relevant database entry in config/databases.yml instead.

  # Output filename prefixes (all written to dada2/Tables/):
  output:
    seq_table_prefix: "seqtab_nochim"
    fasta_prefix: "asvs"
    taxa_prefix: "taxonomy"
```

**Outputs written to `projects/{name}/{run}/dada2/Tables/`:**

| File                      | Contents                                               |
| ---------------------------| --------------------------------------------------------|
| `seqtab_nochim.csv`       | Chimera-free ASV count table (samples x ASVs)          |
| `asvs.fasta` / `asvs.csv` | ASV sequences with short identifiers (seq1, seq2, ...) |
| `taxonomy.csv`            | Taxonomy assignments per ASV                           |
| `taxonomy_bootstraps.csv` | Bootstrap confidence values per rank                   |
| `taxonomy_combined.csv`   | Taxonomy ├ bootstrap columns combined                  |
| `tax_counts.csv`          | Taxonomy ├ per-sample counts                           |
| `asv_counts.csv`          | ASV sequences ├ per-sample counts (no taxonomy)        |
| `pipeline_stats.csv`      | Read counts retained at each pipeline stage            |

### Configuring vsearch (`vsearch:` in `pipeline.yml`)

Controls the alignment thresholds used when assigning taxonomy against the reference database. Per run, this provides the same configuration for both ASV and OTU pipeline if they are running parallel.

```yaml
vsearch:
  identity: 0.75        # minimum sequence identity (--id)
  query_cov: 0.8        # minimum fraction of query covered (--query_cov)
  maxaccepts: ~         # stop after this many hits per query, null = vsearch default
  maxrejects: ~         # max rejected candidates, null = vsearch default
  strand: ~             # "plus" or "both"; null = vsearch default
  optional_args: ""     # additional flags passed verbatim to vsearch
```

### Configuring cd-hit-est (`cdhit:` in `pipeline.yml`)

Optional clustering step that collapses near-identical ASVs before vsearch taxonomy assignment. Used here for when using primers in multiplex, to reduce inflation from same sequences from different primers appearing different.

```yaml
cdhit:
  identity: 1           # sequence identity threshold (-c)
  threads: 0            # worker threads; 0 = all available (-T)
  optional_args: ""     # additional flags passed verbatim to cd-hit-est
```

### Configuring swarm (`swarm:` in `pipeline.yml`)

OTU clustering pipeline run in parallel with DADA2. Produces an OTU count table and FASTA which are carried through vsearch taxonomy assignment and `merge_taxa` alongside the ASV outputs.

```yaml
swarm:
  differences: 1          # -d: max differences between sequences in the same cluster
  threads: 0              # -t: worker threads; 0 = all available
  chimera_check: true     # run vsearch --uchime_denovo before clustering
  min_abundance: 2        # --minsize: discard singleton dereps before clustering
  fastq_minovlen: 20      # min overlap for paired-end merging
  identity: 0.97          # --id: threshold for mapping reads back to OTU seeds
  optional_args: ""       # additional flags passed verbatim to swarm
```

### Configuring merge_taxa (`merge_taxa:` in `pipeline.yml`)

Controls which filter configs are applied when merging taxonomy and count tables. `merged.csv` (unfiltered) is always written; each entry in `filters` produces an additional filtered CSV.

```yaml
merge_taxa:
  filters:
    - "protist_filter.yml"   # -> merged/protist_filter.csv
```

Each entry is a filename relative to `config/filters/`. Remove all entries (or set `filters: []`) to produce only the unfiltered `merged.csv`.

### Configuring analysis (`analysis:` in `pipeline.yml`)

Controls the analysis charts served by the API endpoints (alpha diversity, taxa bar, NMDS, etc.).

```yaml
analysis:
  taxa_bar:
    top_n: 15                  # collapse taxa below this rank to "Other"
    rank: ~                    # null = lowest assigned rank; or specify e.g. "Class"
  alpha:
    metrics: ["richness", "shannon", "simpson"]
  nmds:
    distance: "bray_curtis"
    max_stress: 0.2            # warn if NMDS stress exceeds this value
```

### Configuring taxonomic filtering (`config/filters/`)

Each file in `config/filters/` defines one biological group to extract from the merged table. Filters are applied after the taxonomy/count merge and produce one additional CSV per entry in `merge_taxa.filters`.

#### Database-specific filters

Filter files carry a `databases:` key so that each filter is only applied when the active database matches. The following filters ship in `config/filters/`:

| Category | PR2 match |
|----------|-----------|
| `bacteria_archaea` | `Domain` = Bacteria\|Archaea |
| `environmental_protozoa` | `Subdivision` = Cercozoa\|Gyrista\|Ciliophora\|Chrompodellids |
| `fungi` | `Subdivision` = Fungi |
| `helminths` | `Class` = Nematoda (excl. *Miculenchus*) |
| `parasitic_protozoa` | `Subdivision` = Apicomplexa\|Parabasalia\|Fornicata\|Bigyra |
| `plants_invertebrates` | Exclusion-based (PR2 ranks) |
| `protist` | Exclusion-based (PR2 ranks) |
| `vertebrates` | `Class` = Craniata |

Example:

```yaml
# fungi.pr2.yml
databases: [pr2]

filters:
  - column: Subdivision
    pattern: Fungi
    action: keep        # keep rows matching the pattern (default action is exclude)

remove_empty:
  - Subdivision
```

#### Filter file format

```yaml
databases: [pr2]          # omit to apply regardless of active database

mappings:                 # optional column remapping applied before filters
  - source_column: Division
    target_column: Supergroup
    values: { Rhizaria: Rhizaria, Alveolata: Alveolata }

filters:
  - column: Domain
    pattern: "Bacteria|Archaea"
    regex: true           # false (default) = substring match
    action: exclude       # exclude (default) | keep

remove_empty:             # remove rows where this column is blank or "NA"
  - Domain
```

## Deployment 

### Local (single machine)

```bash
bash start.sh
```

Open `http://localhost:8080`. The backend serves the frontend automatically.

## Input data

Place paired-end FASTQ files under `data/{project_name}/` following Illumina naming:

```
data/MyProject/SampleName_*_L001_R1_001.fastq.gz
data/MyProject/SampleName_*_L001_R2_001.fastq.gz
```

For multi-run projects, nest runs in subdirectories. The server detects any directory containing `.fastq.gz` files as a leaf run and creates a matching project directory under `projects/{project_name}/`.

## Output structure

All outputs for a given run live under `projects/{project_name}/{run}/`:

```
projects/{project_name}/{run}/
├── cutadapt/                    # Trimmed FASTQ pairs and logs
│   └── logs/
├── QC/
│   ├── fastqc/                  # Per-file FastQC HTML reports
│   ├── multiqc_report.html      # MultiQC summary across all samples
│   └── logs/
├── dada2/
│   ├── Tables/
│   │   ├── seqtab_nochim.csv    # ASV count table
│   │   ├── asvs.fasta           # ASV sequences
│   │   ├── asvs.csv             # ASV sequence index
│   │   ├── taxonomy.csv         # Taxonomy assignments
│   │   ├── taxonomy_bootstraps.csv
│   │   ├── taxonomy_combined.csv
│   │   ├── tax_counts.csv       # Taxonomy + per-sample counts
│   │   ├── asv_counts.csv       # Sequences + per-sample counts
│   │   └── pipeline_stats.csv
│   ├── Figures/                 # Quality profile and error rate PDFs
│   ├── Checkpoints/             # RData checkpoints for stage resumption
│   └── Logs/                    # Per-stage R logs
├── cdhit/
│   ├── asvs.fasta               # Clustered ASV sequences
│   └── asvs.fasta.clstr         # Cluster membership file
├── swarm/
│   ├── otus.fasta               # OTU representative sequences
│   ├── otus.count_table.csv     # OTU count table (samples x OTUs)
│   └── logs/
├── vsearch/
│   ├── taxonomy.tsv             # Top-hit taxonomy assignments (ASV or OTU)
│   └── logs/
└── merged/
    ├── merged.csv               # Merged taxonomy + counts (all taxa)
    ├── protist_filter.csv       # Filtered subset (one per merge_taxa.filters entry)
    └── results.duckdb           # DuckDB database for API queries
```

## REST API

The server exposes a REST API under `/api/v1/`. Key endpoint groups:

| Group     | Endpoints                                          | Description                                            |
| -----------| ----------------------------------------------------| --------------------------------------------------------|
| Studies   | `GET/POST/DELETE /studies`                         | List, create, rename, delete studies                   |
| Groups    | `POST/DELETE /studies/{study}/groups`              | Create, rename, delete groups                          |
| Runs      | `GET/POST/DELETE /studies/{study}/runs`            | List, create, rename, delete runs                      |
| Config    | `GET/PATCH/DELETE /studies/{study}/config`         | Read and edit pipeline config at any cascade level     |
| Pipeline  | `POST /studies/{study}/pipeline`                   | Launch pipeline jobs (full study or individual stages) |
| Jobs      | `GET/DELETE /jobs`                                 | Monitor and cancel running pipeline jobs               |
| Results   | `GET/POST /studies/{study}/runs/{run}/results/...` | Query DuckDB tables, apply filter presets, export      |
| Analysis  | `POST /studies/{study}/runs/{run}/analysis/...`    | On-demand alpha, taxa-bar, pipeline-stats charts       |
| Cross-run | `POST /studies/{study}/analysis/...`               | Alpha comparison, NMDS, PERMANOVA across runs          |
| Databases | `GET/POST /databases`                              | List and download taxonomy databases                   |

All responses are JSON. Analysis endpoints return Plotly chart specifications.

## Architecture

```
frontend/           TypeScript + React + Vite (SPA)
src/
  core/             Types, config cascade, validation, DuckDB store, logging
  pipeline/         Pipeline stages (cutadapt, dada2, swarm, vsearch, cd-hit, merge_taxa)
  analysis/         Diversity metrics + Plotly chart builders
  server/           Oxygen.jl HTTP server
    routes/         REST API route handlers
config/             Default configs, filters, CI fixtures
data/               Input FASTQs (user-managed)
projects/           Pipeline outputs (generated)
```

Each pipeline stage returns a typed result (`TrimmedReads`, `ASVResult`, `OTUResult`, `TaxonomyHits`, `MergedTables`) and skips automatically if outputs are already up to date (mtime-based for files, content-hash-based for configuration). Rerunning after a config change only re-executes the minimum necessary stages.

## Third-party tools

This project orchestrates the following tools. Each is fetched from its upstream source by `install.sh` and is subject to its own licence; no third-party binaries are included in this repository.

| Tool                                            | License | Source                  |
| -------------------------------------------------| ---------| -------------------------|
| [cutadapt](https://github.com/marcelm/cutadapt) | MIT     | PyPI                    |
| [FastQC](https://github.com/s-andrews/FastQC)   | GPL v3  | Babraham Bioinformatics |
| [MultiQC](https://github.com/MultiQC/MultiQC)   | GPL v3  | PyPI                    |
| [DADA2](https://benjjneb.github.io/dada2/)      | LGPL v3 | Bioconductor            |
| [swarm](https://github.com/frederic-mahe/swarm) | GPL v3  | GitHub Releases         |
| [vsearch](https://github.com/torognes/vsearch)  | GPL v3  | GitHub Releases         |
| [cd-hit](https://github.com/weizhongli/cdhit)   | GPL v2+ | GitHub Releases / apt   |

## Acknowledgements

This pipeline draws on the following prior work:

- **Frédéric Mahé**: [Fred's metabarcoding pipeline](https://github.com/frederic-mahe/swarm/wiki/Fred's-metabarcoding-pipeline) informed the overall workflow architecture, namely the sequencing of primer trimming, `swarm.jl`, vsearch-based taxonomy assignment, and the final table merge/filter stages.
- **Benjamin J. Callahan _et al._**: [DADA2 tutorial](https://benjjneb.github.io/dada2/tutorial.html), used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), on which `dada2.jl` and its modules are based.

The following colleagues at the **Department of Parasitology, Charles University** (Faculty of Science, BIOCEV, Vestec, Czech Republic) contributed to this work:

- **Mgr. Jiří Novák** (supervisor): scripts from which several modules and configurations were adapted.
- **doc. Mgr. Vladimír Hampl**: provided laboratory access and resources.

## Licence

Copyright © 2026 Joshua Benjamin Jewell.

Source code is licensed under the [GNU Affero General Public License v3.0](LICENSE).

This documentation (README.md) is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
