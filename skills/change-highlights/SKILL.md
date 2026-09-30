---
name: change-highlights
description: Build a stakeholder-facing before/after "highlights" PDF that shows a client what a change does to something they rely on -- an overview, a before example, an after example, and a plain-language explanation -- one PDF per recipient, with a gate that refuses to write a file containing another tenant's identifiers. Covers forward-only fixes through a labeled, constructed example. Use when the user asks to "make a highlights PDF", "build a before/after PDF for <issue>", "show the client what changed", "make a change summary for <recipient>", or invokes the change-highlights skill. Plain Ruby plus a headless Chromium-family browser.
---

# Change highlights

Produce a clear, visual, non-developer-facing PDF that shows a client
stakeholder what a change does to a report, receipt, statement, email, or
screen they rely on: an **overview**, a **before** example, an **after**
example, and a plain-language **explanation** of what changed and why their
figures are still correct.

One PDF per recipient, meant to hold **only that recipient's data**: the
renderer refuses to write a page whose text names another tenant on its deny
list, and lists every image for you to check by eye.

`SKILL_DIR` below is this skill's own directory.

## Read the project's policy first

**Before writing any manifest, check for `.claude/change-highlights.md` in the
project and read it when it exists.** A project keeps its policy for these
documents there, covering what this skill cannot know:

- who the recipients are, and which identifiers belong to each (the `allow`
  and `deny` lists start here);
- anyone authorized to see more than one tenant's data, and the order in
  which to prefer example sources for them (their own organization's records
  first, another tenant's next, constructed data last is a common shape);
- how to run code in the project's environment (a container wrapper, the
  command that refreshes a development database from a production copy);
- the hosts and pages the capture strategies below should use.

The file lives in `.claude/` rather than `.claude/rules/` on purpose: a rules
file without path limits loads into every session in the project, and this
policy can name people
and their data access, which only this skill needs. When the file is absent,
ask the user who the recipient is and which other tenants' names must not
appear, and offer to write the answers there for next time.

**A manifest with an empty `deny` list is not ready to build**, and the
renderer refuses it: the gate would have nothing to check. Fill the list from
the policy file, or ask the user; never fill it with guessed names. The one
exception is a product with a single client, which the policy file or the user
has to say; the manifest then sets `"segregation": {"single_client": true}`.

## Lead with the fix, not with what moves on their records

The document opens with **the change the recipient cares about** -- the bug
fixed or the feature added -- even when that change moves nothing on the
records they already have. Anything else the release corrects that is
cosmetic or leaves totals unchanged is a **later** section, never the opening.

The tempting order is the wrong one. Scoping a document by "what visibly
changes on this recipient's existing records" puts the retroactive display
corrections first and drops a forward-only fix entirely, because a
forward-only fix has no before/after on their history to show. A recipient
who reported a problem then opens a document that never mentions it, and
instead shows figures moving under a heading that says nothing about money
changed. They read it as the opposite of a fix, and they read it correctly:
the fault is the document's scope, not their comprehension.

So, in order:

1. **The fix or feature**, named in the recipient's own terms, ideally echoing
   how they described the problem. If it is forward-only, say so plainly and
   show it with a constructed example (capture strategy 4) rather than
   leaving it out, **labeled "Example only"** so the reader does not think
   their history changed.
2. **What they will observe**, including "nothing changes on your existing
   records" when that is the honest answer.
3. **Everything else the release touches**: display corrections, relabelings,
   secondary cleanups.

Two things belong in the overview (`intro`), not only further down:

- **What the fix does not do.** If the release stops a problem going forward
  but does not undo what already happened, say so in the overview, where they
  cannot miss it.
  A recipient who learns that limit on a call, after reading a document that
  implied the matter was closed, has been misled by the document.
- **A concrete case of theirs**, when one exists. One of their own records,
  with its real figures, does more than any amount of explanation.

`SKILL_DIR/examples/sample_manifest.json` follows this order.

## How the work divides

- **Capture** (producing the before/after material) is **per change**: there
  is no general way to detect "the visible change". The strategies below
  guide it, and you still pick the example records and write the explanation.
- **Assembly and rendering** (manifest to HTML to gate to PDF) is the same
  every time, and the scripts here own it.

Everything converges on one artifact per recipient: a **highlights manifest**
(JSON). Capture produces the raw material; you fold it into a manifest; the
builder takes it from there.

## Files

- `build_highlights_pdf.sh` -- for each manifest: render the HTML (the gate
  runs), print it to PDF with a headless browser and no network, confirm the
  PDF has pages, and list the images the gate could not read.
- `render_highlights.rb` -- manifest to HTML, plus the segregation gate.
  Stdlib Ruby only.
- `find_chrome.sh` -- finds Chrome, Chromium, Brave, or Edge; `CHROME=/path`
  overrides it.
- `templates/capture_snapshot.rb` -- capture strategy 1, a Rails runner
  template you copy and edit per change.
- `capture_screenshot.sh` -- capture strategies 2 and 3, a headless
  screenshot of a URL (a `file://` URL takes an absolute path). The window is
  1200 by 2400 pixels, so anything below 2400 is cut off; `WIDTH` changes the
  width, and `PROFILE` names a browser profile directory to reuse a signed-in
  session, which works only while no running browser has that profile open.
- `examples/sample_manifest.json` -- a complete manifest to copy from.

## Build

```bash
bash SKILL_DIR/build_highlights_pdf.sh path/to/recipient.json [more.json ...]
# -> path/to/recipient.html and path/to/recipient.pdf
```

Render only, to iterate on layout without a browser:

```bash
ruby SKILL_DIR/render_highlights.rb path/to/recipient.json
```

Keep manifests and their output out of the repository (a gitignored `tmp/` is
conventional): they hold client data. Each manifest's name must end in
`.json`.

Both scripts exit 0 when every PDF (or page) is written, 1 when the gate
refuses a manifest or anything else stops the build, and 2 when run with the
wrong arguments. The builder deletes each manifest's earlier `.html` and
`.pdf` before building; after a refusal partway through, the PDFs already
built for earlier manifests remain and later manifests are not built.

## The manifest

```jsonc
{
  "title": "Your invoices: what's changing",
  "intro": ["first paragraph, **bold** allowed", {"list": ["a bullet"]}],
  "preview_caveat": "optional; renders a bold note -- see below",
  "currency_symbol": "$",                          // optional, default "$"
  "segregation": {
    "allow": ["Recipient Co"],                     // SHOULD appear (warns if absent)
    "deny":  ["Other Co", "Third Co"]              // MUST NOT appear (no file written);
                                                   // other tenants, from .claude/change-highlights.md
    // or "single_client": true in place of deny, for a product with one client
  },
  "examples": [
    {
      "heading": "The fix: ...",
      "explanation": "what changed, and why the figures are right",
      "blocks": [ /* one or more blocks, in order */ ]
    }
  ]
}
```

Block types, mixed freely within an example:

- **`comparison_table`** -- before/after amounts. Fields: `title`,
  `row_header`, `before_label` (default `BEFORE`), `after_label` (default
  `AFTER`), `rows: [{label, before_cents, after_cents}]`, optional
  `no_change_note`.
  The after amount is bolded when it differs from the before amount.
- **`amount_table`** -- an itemized list with a total. Fields: `title`,
  `label_header` (default `Description`), `amount_header` (default `Amount`),
  `total_label` (default `Total`), `empty_note` (default "Nothing to show this
  period."),
  `rows: [{label, amount_cents, info?}]`. The total is the sum of the rows
  shown, so it always reconciles. To mark a row that does not affect what the
  recipient owes, give it an `info` tag and say so in the explanation; never
  drop it from the sum, since a total that excludes a visible row reads as a
  bug.
- **`image`** -- `{src, caption}`. A PNG file that exists: a relative `src`
  resolves against the manifest's directory, and an absolute path or a
  `file:///` URL names the file directly. The renderer follows symlinks and
  checks the file's first bytes, and refuses anything that is not a PNG. An
  SVG's text would print as text the gate cannot read, and a JPEG goes into
  the PDF whole, metadata included; convert either to PNG (a screenshot
  already is one). A remote source (`http://`, `https://`, `//host/...`) is
  refused, so download the image and use the local copy, and so is a `data:`
  source, which leaves no file to review. For a feature that only adds
  something, include just the after image.
- **`image_row`** -- `{images: [{src, caption}, ...]}`, side by side, e.g.
  before and after screenshots.
- **`text`** -- `{content}`, text between tables and images; `content` is
  required.

Every field is text, and the renderer escapes it and writes every tag
itself, so the segregation gate reads exactly what the browser prints.
`intro`, `explanation`, and a `text` block's `content` take one paragraph
as a string, or a list whose items are paragraphs and `{"list": [...]}`
bullet lists. The only markup is `**bold**`. The older raw-HTML fields
(`intro_html`, `explanation_html`, `html` blocks) are refused, with the
replacement named.

The page carries a Content-Security-Policy that blocks scripts, frames, and
every load but local images, and the builder prints with every request the
browser makes sent to a proxy that answers nothing.

The renderer also refuses, naming the problem in one line: a manifest that
is not a JSON object; an amount that is not a whole number of cents (a
missing amount reads as zero); an unknown block `type`; an image with no
`src`, or one that is missing or not a PNG; text that is not paragraphs and
`{"list": [...]}` items; `segregation` that is not an object, or a manifest
with no `deny` list that does not set `single_client`; examples, blocks,
rows, or images that are not lists of objects; and an output path that is
the manifest itself. A missing `title` reads as "What's changing".

## Capture strategies

Pick by the kind of change. Run before and after over the **same data**, so
the two differ only by the code change. Staging and production are separate
datasets; comparing one with the other is valid only for a purely visual
change.

### 1. Data snapshot -- numeric and report changes

Record the computed values under each code version, then fold the two into a
manifest.

1. Load a development database from a production copy (the project's policy
   file names the command), so before and after run over identical rows.
2. Copy `SKILL_DIR/templates/capture_snapshot.rb` to `tmp/` and edit its
   three marked sections: which records, how to find and name them, and what
   to compute for each.
3. Run it under the after code (the feature branch) and again after checking
   out the pre-change commit:
   ```bash
   OUT=tmp/after.json  bin/rails runner tmp/capture_snapshot.rb
   git switch --detach <pre-change-commit>
   OUT=tmp/before.json bin/rails runner tmp/capture_snapshot.rb
   git switch -   # back to the feature branch
   ```
   If the feature branch added a migration, the pre-change code runs against
   a database that already has it; capture "before" first on a fresh copy
   when the schema matters.
4. Fold `before.json` and `after.json` into one manifest per recipient:
   `comparison_table` rows for totals, an `amount_table` for an itemized
   section, and your explanation. This fold is the judgment step.

### 2. Page screenshot -- UI and layout changes

Capture the same page under before and after code with
`capture_screenshot.sh`, then reference the images as `image` or `image_row`
blocks.

```bash
bash SKILL_DIR/capture_screenshot.sh "http://localhost:3000/some/page" tmp/after.png
```

A headless browser has no signed-in session. Rather than driving a signed-in
browser, which tends to break (sessions time out mid-capture, and other
browser extensions can block clicks and typing), render the page to a file
and screenshot that:

1. Load a development database from a production copy.
2. In a Rails runner, sign in and fetch the page with
   `ActionDispatch::Integration::Session`, with
   `ActionController::Base.allow_forgery_protection = false`. No browser
   session is involved.
3. Keep the **whole document**, and add
   `<base href="http://localhost:<port>/">` to its `<head>` so relative asset
   paths resolve against the running development server. Trim it to a few
   rows by removing table rows.
4. Check out the pre-change commit and repeat for "before".
5. Screenshot each `file://` path with `capture_screenshot.sh`.
6. Crop to the part that changed (`sips -c <height> <width> --cropOffset
   <top> <left>` on macOS, `magick in.png -crop WxH+X+Y out.png` with
   ImageMagick).

What goes wrong, and why:

- **Copying just the `<table>` into a hand-built page.** The app's CSS
  depends on wrapper classes, so the table can render with borders and
  invisible text. Keep the whole document.
- **Crop offsets past the image edge.** In one case `sips` padded the result
  with a solid black block instead of failing. Check that offset plus size
  stays within the image.
- **Signing in as an arbitrary user on a production copy.** Many real
  accounts require two-factor sign-in or are inactive. A failed sign-in
  usually answers with a redirect back to the sign-in form, so a redirect
  status alone does not say whether it worked. Choose the user by filtering
  on the conditions the app's sign-in checks.

### 3. App-generated artifact -- receipts, emails, PDFs

Have the app render the artifact to a local `.html` or PDF under each code
version, then screenshot the `file://` path (no session needed) and use the
image in an `image` block.

### 4. Constructed scenario -- forward-only changes

Use when the change has **no before/after on the recipient's existing
records** because it takes effect only on a future event.

1. Load a development database from a production copy and, where possible,
   build the scenario on one of the **recipient's own** records.
2. In a Rails runner, set up the scenario and perform the triggering action,
   once under the after code and once under the pre-change commit, recording
   the resulting figures or screen each time. Wrap each run in a transaction
   that rolls back, so the scenario never persists:
   `ActiveRecord::Base.transaction { ...; raise ActiveRecord::Rollback }`.
3. Fold the two results into a `comparison_table` or screenshots, as in
   strategy 1.
4. **Label it as an example.** The heading or explanation must say this
   shows how a future event will behave, not a change to the recipient's
   history, e.g. "Example only. Your existing records will not change; this
   shows how the next <event> will be recorded." Without it, a reader will
   think their past records were altered.

Segregation still applies: any real record used as the base must be the
recipient's own.

## The segregation gate

`render_highlights.rb` searches the rendered page for every `deny` token and
**refuses to write the file** if any appears, deleting any page an earlier run
left behind. It searches the text a reader would see (tags removed, entities
decoded, whitespace collapsed, the renderer's own stylesheet skipped) and the
image paths and captions in the page's attributes. Page and token are first
put into one comparable form: case folded, compatibility characters such as
full-width letters and decomposed accents normalized, invisible characters
such as soft hyphens and zero-width spaces dropped, and every dash and the
minus sign made a hyphen. So a token cannot slip through as escaped
characters, a word split by a tag, a name wrapped across lines, or a name
copied from app data with invisible characters in it.

`allow` and `deny` must each be a list of strings with no blank entries; the
renderer refuses anything else rather than check a page against a list it
cannot use. Surrounding spaces on a token are ignored.

What it cannot do:

- **Read images.** A "before" screenshot can show another tenant's rows. The
  builder lists every image as not scanned; look at each one.
- **Match whole words only.** A token matches inside longer words, so a short
  one (a three-letter abbreviation) will refuse pages it should not. Pick
  distinctive tokens: full company names, account-number prefixes.
- **Know who the other tenants are.** The `deny` list is only as good as its
  author; build it from the project's policy file or the database, not from
  memory.

`allow` lists the recipient's own identifiers. One missing is a warning, not
a failure: it usually means the manifest is for the wrong recipient.

Always look at the final PDF itself before sending it; the Read tool renders
its pages. The HTML shows content and layout but not page breaks, so a claim
that an example fits on one page, made from the HTML, says nothing about the
PDF anyone receives.

## Writing the copy

Everything in `intro`, each `explanation`, `text` blocks, and any ask or
decision is written as the user, to someone outside the team:

- **First person singular.** The user is the person accountable for the
  work: "I updated your receipts", "let me know and I'll proceed".
- **Future tense before the change reaches them.** A document sent before
  release describes what will happen, including what will not change: "your
  totals will stay the same", "the next invoice will show". Present tense
  ("your totals stay the same") leaves the reader guessing which side of the
  change a sentence describes.
- **Nothing that goes stale in days.** Avoid "In early June I ..." while it is
  still early June; prefer wording that stays true, such as "Earlier this
  month I ...".
- Follow the team's own writing rules for punctuation and tone.

## "Preview only" note

When you build an example by running the after code over an older period's
data (new code over last month's records), set `preview_caveat` to the note
itself, which renders as given in a bold box under the overview. Write it
yourself; there is no default wording. Say that the recipient will not see
this in production until new activity occurs, e.g. "Preview: these figures
come from last month's records run through the new code. Your statements will
show this once this month's activity is recorded." Leave it out for real
production output.

## Rendering lessons (keep them)

- **Print with a Chromium-family browser, not wkhtmltopdf**, which shrank
  content whose fixed `max-width` was wider than the page when this skill was
  built. The working flags
  are in `build_highlights_pdf.sh`.
- **Print CSS:** `@page { size: Letter; margin: 0.5in }`, `body { margin: 0 }`,
  no fixed `max-width`, base font about 15px. To fit a dense example on one
  page, tighten padding and margins rather than shrinking fonts.
- **An example stays on one page when it fits.** Each example is one card
  with `break-inside: avoid`, so a total is not stranded on the page after the
  rows it sums. A card taller than a page still breaks; split it into two
  examples, and check the PDF itself.
- **Stdlib Ruby only** in the renderer, so it runs with a plain `ruby` and no
  Rails.

## Related

The markdown-to-pdf skill (bundled in this plugin) turns a Markdown file into
a PDF. Use it for a document that is prose; use this skill when the document
is built from captured before/after material for a specific recipient.
