# [Feature] Port the WorkBuddy adaptation experience to Codex Desktop (background transparency at the token layer)

<!--
如何提交：
  gh issue create -R starsstreaming/beautiCode \
    --title "[Feature] Port the WorkBuddy adaptation experience to Codex Desktop (background transparency at the token layer)" \
    --body-file docs/issue-workbuddy-to-codex.md
  （草稿文件本身带了这一层 HTML 注释，提交前可删；正文从下面第一行开始。）
-->

## TL;DR

In #63 the maintainer asked for a WorkBuddy adapter. That work is now done on
`feat/workbuddy-background` and it produced a method, not just a feature: measured
layer discovery → transparency at the **token layer** → one alpha per visual group →
machine-checkable invariants. Codex Desktop is the reference host for
`docs/host-adapter.md`, so it should inherit the method.

**The one real conflict:** Codex's current CSS contract forbids
"clearing host token surface backgrounds globally" (`docs/host-adapter.md`,
*Forbidden*). WorkBuddy wins by doing exactly that — deliberately, scoped, and
keyed to the host's own theme selectors. Porting therefore needs an explicit
decision on that clause, not just new selectors.

---

## 1. Context: what the WorkBuddy round actually produced

Branch `feat/workbuddy-background`. Injection-only over CDP — no host file is
touched, and everything is reversible.

| File | LOC | Role |
|---|---|---|
| `packages/adapter-workbuddy/src/contract.ts` | 318 | DOM/CSS contract as data: backdrop / surface / flatten / mask selectors, anchors, theme keys |
| `packages/adapter-workbuddy/src/token-overlay.ts` | 398 | Token scan (page-side string) + overlay generator + hard-coded-surface sweep |
| `packages/adapter-workbuddy/src/background-bar.ts` | 614 | Sidebar entry + popover panel + stage/media runtime (idempotent IIFE) |
| `packages/adapter-workbuddy/src/target.ts` | 98 | Target-page identification + URL redaction |
| `packages/adapter-workbuddy/src/color.ts` | 54 | `rgb/rgba/color(srgb)/#hex` → alpha |
| `packages/adapter-workbuddy/src/host-descriptor.ts` | 24 | Capability bits |
| `scripts/wb-cdp-runner.mjs` | 747 | Resident daemon: connect → apply sequence → watch → picker bridge → gallery |
| `scripts/wb-setup.mjs` | 258 | LaunchAgent/bootstrap helpers |
| `packages/adapter-workbuddy/test/*.test.js` | 371 | 29 unit tests pinning the invariants below |

Reused unchanged from `@beauticode/core`: `ApplyTransaction`, media
validation/source, background store, file lock, error messages, paths. On the
Codex side `packages/adapter-codex/src/cdp.ts` and `injector-lock.ts` carried
over as-is — the CDP layer is genuinely host-independent.

---

## 2. The method (this is the portable part)

### 2.1 Measure, never infer

Static analysis of the asar was **wrong** twice. Runtime DOM differs from what
the bundle suggests (routing-dependent subtrees), and CSS Module class names are
hashed. What worked:

- Enumerate `document.styleSheets` rule by rule and call `el.matches()` to
  attribute every background to the exact rule and token that paints it.
- Build a coverage table: `element area / viewport area`, with the colour source.
  For WorkBuddy that produced nine measured layers from 100% down to 6.9%.
- Re-probe after every host update. The numbers, not the selectors, are the
  durable artifact.

### 2.2 Unify CSS at the token layer, not at the selector layer

WorkBuddy paints backgrounds through **2370 rules across 4 token families**
(`--wb-*` shell, `--cb-*` legacy chat, `--cr-*` conversation renderer, `--sk-*`
embedded sub-app), plus VS Code design tokens (`--vscode-*`, `--qad-*`, `--ic-*`)
on most feature pages. Enumerating selectors is hopeless; the official skin
system does not do it either. So we override the **tokens**, keyed on the same
theme selectors the host itself uses.

Four mechanisms, with **non-overlapping** responsibilities:

| Mechanism | Covers | Where |
|---|---|---|
| Token overlay | everything driven by host tokens — including pages/modals/dialogs we have never seen | `token-overlay.ts` |
| Pinned surface rules | the handful of surfaces we measured; derived from **our own** opaque base colour | `contract.ts` `SURFACE_RULES` |
| Hard-coded neutralisation | surfaces painted with a **literal** colour that no token can reach | `token-overlay.ts` `HARDCODED_SURFACE_*` |
| Flatten / backdrop / mask / stage | what tokens cannot express | `contract.ts` |

**Invariant: mechanisms must never stack on the same pixel.** Pinned rules derive
from `--bc-surface-base` (our per-theme opaque colour) and reference no host
token, so a surface covered twice stays `0.82`, not `0.82 × 0.82 ≈ 0.67`.

### 2.3 One alpha per visual group

Style rule adopted after the user reported a "mixed look":

- backdrop region (shell, conversation main, sidebar list body) → **transparent**
- floating layers (sidebar panel, composer, code blocks, tool cards, widget cards, bubbles, right-hand artifact cards) → **one shared alpha**
- sub-surfaces inside a floating layer (card header/body, diff viewport, composer toolbar, model picker) → **transparent** (flattened)
- semantic tints (diff add/remove rows) → **left opaque** on purpose

Alpha is multiplicative: container 0.82 + child 0.82 ≈ 0.97 reads as solid. That
is exactly the "the composer is translucent but the model picker inside it is
opaque" bug. `0.82` was chosen because it was already accepted on content cards,
and below ~0.7 code text loses contrast on a mid-tone wallpaper in light theme.

### 2.4 Invariants as executable checks

These are the assertions worth porting verbatim:

1. The set of alpha values across all translucent elements has size **1**.
2. **No element carrying alpha has an ancestor carrying alpha.**
3. Horizontal overflow `scrollWidth - innerWidth <= 1`.
4. Visibility sampling: 11×7 grid, `document.elementsFromPoint` per point; **exclude
   `body` and `html`** — their backgrounds paint *below* the stage and otherwise
   produce a false "100% occluded".
5. Two consecutive applies are **idempotent** (measured token counts identical).

---

## 3. Pitfalls that cost the most time (with the fix)

Each of these was a user-visible bug. They are the reason this issue is long.

1. **`calc()` inside `color-mix()` is invalid in Chromium** → the declaration is
   silently dropped, so it "looks applied" and does nothing. Use a **literal
   percentage**.
2. **`!important` is mandatory on token overrides.** The host re-declares the same
   token closer to the element, so a plain `html:root` override loses on the
   element: reads translucent at `:root`, solid white on the composer.
3. **Some families are dark-first.** `--cr-*` declares a dark value at `:root`;
   resolving by "does the selector mention dark" paints dark values onto the light
   theme. Fix: bucket declarations into light/dark/neutral by selector intent and
   resolve in theme-first order, falling back to the computed value last.
4. **Emit both themes, keyed on the host's own classes**, and never on "which
   theme was active at inject time" — that produced white-on-white after a switch
   to dark.
5. **Never touch foreground tokens.** `--wb-bg-primary-fg` merely *contains* `bg`;
   overriding it makes text invisible.
6. **The scan must skip its own sheets**, or a re-apply consumes the overlay it
   wrote last round, re-mixes `color-mix` values, and drifts on every run.
7. **Hard-coded literal surfaces need a chroma filter.** Neutralise near-greys
   (chroma ≤ 24) only; keep saturated colours — buttons, logos, QR codes,
   category swatches, the terminal — or meaning is destroyed.
8. **Read computed values at the root, not declarations**, because the semantic
   layer is almost entirely aliases (`--wb-bg-primary: var(--wb-palette-white-100)`).
9. **Style ordering.** The host appends `<style>`/`<link>` at runtime (328 `<head>`
   children measured, 97 of them landing *after* our first sheet). At equal
   specificity and importance the later declaration wins, so the host quietly took
   the cascade back and feature pages stayed solid.
   **But do not fight another keeper:** WorkBuddy ships its own
   `cb-font-size-override` re-sorter. Two keepers each pinning themselves to the
   end of `<head>` produced measurable **16Hz style churn**. On WorkBuddy our
   keeper is therefore disabled and any already-installed instance is stopped.
   **Check whether Codex has a re-sorter before porting the keeper.**
10. **Theme switches fire 6+ class changes** with an intermediate
    `theme-switching` state. Debounce the `MutationObserver` (**160 ms**) and parse
    the theme from the class **token list** — never compare the class string.
11. **Alpha must be a CSS variable slot**, not a baked literal: generate
    `color-mix(… var(--bc-surface-alpha-pct, 82%) …)` so the panel's opacity
    slider is instant with zero re-injection.
12. **State persistence needs a "blank sample" guard.** The daemon polls the page
    every 1.5 s and writes state; overwriting the archive with a freshly-reloaded
    page's initial `null`s wipes the user's wallpaper. Persist only non-blank
    samples, and reconcile only when the page is genuinely blank.

---

## 4. What Codex needs decided before any code is written

| # | Question | Why it blocks |
|---|---|---|
| 1 | **Does the token-layer route get an exception to the "do not clear host token surface backgrounds globally" clause?** | It is the whole mechanism. Options: scope it to measured token families, gate it behind `data-bc-active`, or keep Codex on explicit selectors and accept partial coverage. |
| 2 | Does Codex Desktop ship a `<head>` style re-sorter (like WorkBuddy's font-size keeper)? | Decides whether the style keeper is ported, adapted, or omitted. Getting this wrong yields a churn loop. |
| 3 | What is Codex's token-family layout — one family or several, and are any dark-first? | Determines the bucketing logic (pitfall 3). |
| 4 | Does Codex run a content webview/iframe for chat, or paint it in the main renderer? | CSS cannot cross into a separately-painted webview. On WorkBuddy the chat is in the main renderer, which is why the token layer reaches it. |
| 5 | Is `file://` direct media reference allowed, or must media go through `DOM.setFileInputFiles` → blob? | WorkBuddy allows `file://` (6.2 MB / 2600×1351 verified), which removes the 128 KiB inline ceiling and the copy step. |

None of these are guesses we can make from the outside; **item 1 is a product
decision, items 2–5 are 10-minute CDP probes.** §2.1 is the probe recipe.

---

## 5. Deliverables if this is accepted

1. `docs/host-adapter.md` §CSS contract updated to describe the token-layer route
   and its guard rails (or an explicit "Codex stays selector-scoped" note).
2. Codex equivalent of `token-overlay.ts` + the scan expression, with the
   light/dark/neutral bucketing and the self-sheet skip.
3. Codex equivalent of the invariants in §2.4 as unit tests — the tests are the
   real deliverable; they are what keeps a host update from silently regressing.
4. Codex layer map (coverage table + colour source per layer), committed to
   `docs/`, regenerated when the host updates.
5. A `verify` pass wired to the existing `ApplyTransaction` rollback path.
6. Regression coverage in `scripts/` for the daemon-side behaviours that bit us:
   blank-sample guard, keeper coexistence, theme-switch debounce.
7. `docs/` note on how to re-measure after a Codex update (the asar-static-analysis
   trap).

---

## 6. Acceptance criteria

- Wallpaper visible under the main surface; visibility sampling ≥ 60%.
- Alpha set across translucent elements has exactly one value; zero nesting violations.
- Two consecutive applies are byte-identical in generated CSS.
- Theme switch light ↔ dark: no white-on-white, no white-on-black, text contrast
  preserved; no re-injection required.
- Horizontal overflow ≤ 1 px.
- `clean` removes every injected node, every `data-bc-*` attribute, and every
  injected sheet — verified by re-probe.
- Detector failures **fail open** (background stays visible), never capture pointer
  events, never touch composer radius/border/shadow.
- No write anywhere under the host's own data directory.

---

## 7. Effort estimate and risks

Rough split from the WorkBuddy round (working days): probes and layer mapping ~1,
CSS contract + token overlay ~2, injection runtime and UI ~2, verify/rollback and
tests ~1.5, theme/remount hardening ~1, docs ~0.5.

Risks:

- **Host update drift.** CSS Module hashes and layered structures change. Mitigated
  by the structural-anchor self-check failing closed: if the anchors stop matching,
  inject nothing and say why — never half-apply.
- **The token-layer exception becomes a maintenance surface.** It is broad by
  design. Mitigated by keeping pinned surfaces on our own base colour and by the
  nesting invariant, so breadth cannot compound into opacity loss.
- **Codex may not need the full method.** Even a partial port is worthwhile: the
  measurement technique (§2.1) and the invariants (§2.4) transfer regardless of
  which mechanism Codex ends up using.

---

## 8. References

- `docs/host-adapter-workbuddy.md` — the full WorkBuddy contract, layer table,
  theme/remount behaviour, verify criteria, security boundaries, and §15 on
  diagnosing "the model stopped responding" (it was upstream latency plus a host
  UI state bug, **not** the injection — kept as a worked example of not blaming the
  adapter by default).
- `docs/host-adapter.md` — host-independent contract; Codex's current CSS rules.
- `docs/security-boundaries.md` — loopback-only CDP, bounded responses, single
  injector lease, no writes into host data roots.
- `docs/apply-transaction.md` — snapshot/commit/rollback used by the verify path.
- Issue #63 — the original WorkBuddy request.
- Issue #65 — WorkBuddy Windows verification checklist (open items there are
  WorkBuddy-specific and do not block a Codex port).

---

<details>
<summary>中文说明（给维护者快速过一遍）</summary>

这一轮把 beautiCode 适配到 WorkBuddy 的经验，想复用到 Codex Desktop 上。要点：

1. **方法是「实测」而不是「推断」**：asar 静态分析错了两次；真正管用的是
   遍历 `document.styleSheets` + `el.matches()` 把每个背景归到具体规则和 token，
   再按「元素面积 / 视口面积」列出分层表。WorkBuddy 量出 9 层（100% → 6.9%）。
2. **CSS 统一做在 token 层，不做在选择器层**：WorkBuddy 有 2370 条规则在写背景、
   4 套 token 家族，逐条枚举不可行；改在 token 层覆盖、挂宿主自己的主题选择器上，
   和官方皮肤机制同路。广度由此拿到（连没见过的弹窗一起透）。
3. **两套机制绝不叠加**：钉住的 surface 规则用**我们自己的**不透明基色派生，
   不引用任何宿主 token，否则会变成 0.82 × 0.82 ≈ 0.67。
4. **一个视觉分组只有一个 α**：容器 0.82 + 子元素 0.82 ≈ 0.97，看起来就是实心 ——
   这正是用户报的「输入框半透明、里面模型选项不透明」。
5. **写成可执行不变量**：α 取值集合只有 1 个值；带 α 的元素不得有带 α 的祖先；
   横向溢出 ≤ 1px；11×7 可见度抽样（要排除 body/html，否则误报 100% 遮挡）；
   连续两次 applied 结果幂等。
6. **最花时间的坑**（正文 §3 共 12 条）：`color-mix` 里的 `calc()` 无效被静默丢弃；
   token 覆盖必须 `!important`；`--cr-*` 深色优先会串到浅色主题；`<head>` 尾部顺序
   被宿主抢回；**但不要跟宿主自己的样式看门狗对着干**（两个 keeper 互钉 = 16Hz 抖动，
   实测过）；主题切换一次触发 6 次以上 class 变更，observer 要去抖 160ms。
7. **需要维护者先定的一件事**：Codex 现在的 CSS 契约明确禁止
   「全局清掉宿主 token 背景」（`docs/host-adapter.md` 的 Forbidden 段）——
   而 token 层正需要这条。建议给一个受控例外（限定在实测的 token 家族内、
   由 `data-bc-active` 门控），或者明确写「Codex 仍走选择器路线、接受覆盖不全」。
   另外 4 项（Codex 是否自带样式看门狗 / token 家族结构 / 聊天是否在独立 webview /
   是否允许 `file://` 直引）都可以用 10 分钟 CDP 探查确认，不需要猜。
8. **真正的交付物是不变量测试**：它们是宿主升级后唯一能挡住静默回归的东西。

</details>
