# Submission Folder — Yield-paca

Lablab.ai hackathon submission files for:
**Alpaca AI Trading Agents Hackathon** (Aug 28 – Sep 4, 2026)

Project name: **Yield-paca**

## Contents

| File | Submission Field | Notes |
|---|---|---|
| `01-project-title.txt` | Project title | Single line, ≤80 chars |
| `02-short-description.txt` | Short description | 1-3 sentence summary |
| `03-long-description.md` | Long description | Full markdown project write-up |
| `04-tech-and-category-tags.txt` | Technology & Category tags | List format for the form's multi-select |
| `05-slide-presentation.md` | Slide presentation (outline) | 10-slide deck to export to .pptx; ascii layout, ASCII-art placeholders for visuals |
| `06-alpaca-paper-account.txt` | Alpaca paper trading account ID | `PA3PR2RMFE9Y` |

## Submission Form Filling Checklist

When pasting into the lablab.ai submission form:

- [ ] **Project title:** `01-project-title.txt`
- [ ] **Short description:** `02-short-description.txt` (one paragraph)
- [ ] **Long description:** `03-long-description.md` (full body; preserve markdown)
- [ ] **Tech tags** (multi-select): pick from `04-tech-and-category-tags.txt`
- [ ] **Category tags** (multi-select): pick from `04-tech-and-category-tags.txt`
- [ ] **Slide deck upload:** convert `05-slide-presentation.md` to `.pptx` (or `.pdf`) and attach
- [ ] **Alpaca paper account ID:** `PA3PR2RMFE9Y`

## Converting the Slide Deck

The `.md` outline is the source of truth. To convert to a real deck:

### Option A — Manual (10 min)
1. Open PowerPoint / Keynote / Google Slides
2. Create a 16:9 blank deck with 10 slides
3. Copy each slide's `Title` and `Bullets` from `05-slide-presentation.md`
4. Drop in screenshots from the running system (dashboard, Temporal
   UI, broker fills)
5. Save as `.pptx` and upload

### Option B — Marp / Pandoc
```bash
# Render to PDF
npx @marp-team/marp-cli 05-slide-presentation.md --pdf

# Render to .pptx via Pandoc
pandoc 05-slide-presentation.md -o deck.pptx
```

Either format is acceptable per the hackathon guidelines.

## Notes for Reviewers

- Live workflow logs at: `http://localhost:8233` (Temporal UI) once
  the worker is up
- Live dashboard at: `http://localhost:5173` (Vue frontend)
- Paper-trading account ID: **PA3PR2RMFE9Y** (Alpaca)
- See `03-long-description.md` for architecture diagrams and the
  full design rationale
