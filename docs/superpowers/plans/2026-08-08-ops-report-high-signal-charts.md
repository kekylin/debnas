# High-Signal Operations Report Charts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add capacity, disk I/O, and service-stability charts to the static seven-day operations report while retaining each supporting detail table.

**Architecture:** Add three inline SVG charts to the existing resource and service report sections. Each chart derives only from values already displayed in its adjacent table, follows the existing white-background and semantic-color system, and retains the table as the detailed reference layer. Update the PRD with chart purpose, data fields, and visual constraints.

**Tech Stack:** Static HTML5, inline SVG, CSS, Playwright browser validation, Markdown PRD.

## Global Constraints

- Preserve the report's flat Apple-style visual system and existing data tables.
- Use inline SVG only; add no JavaScript, CDN, or runtime dependency.
- Use `#0066CC` for primary series, `#86868B` for secondary series, `#D97706` for attention states, and `#C7000B` for errors.
- Include axes, units, legends, and accessible SVG labels.
- Keep charts responsive through the existing `.chart` and `.grid-2` layout rules.

---

### Task 1: Establish browser acceptance checks

**Files:**
- Test: active browser page for `docs/ops-report-sample-7d.html`

**Interfaces:**
- Consumes: the existing static report.
- Produces: a failing check for three missing SVG charts identified by their `aria-label` values.

- [x] **Step 1: Run the missing-chart assertion**

Run a Playwright check requiring one SVG each for `磁盘容量使用情况`, `设备 I/O 周期累计对比`, and `服务稳定性错误与重启对比`.

Expected: the assertion fails because none of the three SVGs exists before implementation.

### Task 2: Add resource charts

**Files:**
- Modify: `docs/ops-report-sample-7d.html`

**Interfaces:**
- Consumes: physical-disk usage, threshold, cumulative read/write, and peak-busy values already shown in the resource tables.
- Produces: two SVGs with `aria-label="磁盘容量使用情况"` and `aria-label="设备 I/O 周期累计对比"`.

- [x] **Step 1: Add a disk-capacity threshold chart**

Place a horizontal 0–100% bar chart before the physical-disk table. Render `/dev/sda`, `/dev/sdb`, and `/dev/sdc`; add a dashed 90% threshold; use amber only for `/dev/sdc`; retain exact percentages and time-to-threshold labels.

- [x] **Step 2: Add a disk-I/O comparison chart**

Place an aligned read/write bar chart next to the capacity chart. Normalize cumulative volume to TB, distinguish read and write in the legend, and annotate each device's peak busy percentage without adding a second numerical axis.

- [x] **Step 3: Run browser checks**

Verify each resource SVG has an axis, legend, expected row labels, and no SVG text overlap at desktop and mobile widths.

### Task 3: Add the service-stability chart

**Files:**
- Modify: `docs/ops-report-sample-7d.html`

**Interfaces:**
- Consumes: per-service period error and restart counts from the service-stability table.
- Produces: an SVG with `aria-label="服务稳定性错误与重启对比"`.

- [x] **Step 1: Add a grouped horizontal bar chart**

Place the chart immediately before the service-stability detail table. Use one row per service, red bars for errors, amber bars for restarts, a count axis from 0 through 4, and a legend explaining both series.

- [x] **Step 2: Run browser checks**

Verify the six service rows, the error/restart series, the zero-count rows, and the highlighted `jellyfin` and `radarr` values render without clipping.

### Task 4: Synchronize the product requirements

**Files:**
- Modify: `docs/design-ops-report.md`

**Interfaces:**
- Consumes: the three chart contracts from Tasks 2–3.
- Produces: versioned PRD rules for chart data, placement, semantics, and table retention.

- [x] **Step 1: Update the PRD version history and chart list**

Add a new version entry describing the three high-signal charts. List disk I/O comparison and service-stability comparison alongside the existing capacity chart recommendation.

- [x] **Step 2: Update resource and service requirements**

Specify the 90% capacity threshold, the TB-normalized I/O chart with peak-busy annotations, and the grouped service error/restart bars. State that every chart supplements rather than replaces its detail table.

### Task 5: Validate the finished report

**Files:**
- Test: `docs/ops-report-sample-7d.html`
- Test: `docs/design-ops-report.md`

- [x] **Step 1: Run HTML and Markdown diagnostics**

Run VS Code diagnostics for both changed files.

Expected: no errors.

- [x] **Step 2: Run browser layout checks**

Use Playwright to confirm all three SVGs exist, each has the required text labels, and labels do not overlap at desktop and mobile widths.

- [ ] **Step 3: Inspect desktop and mobile screenshots**

Capture the resource and service sections, confirm chart axes and legends are readable, and confirm mobile charts fit the single-column layout.
