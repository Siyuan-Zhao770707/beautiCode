# [Feature] Port the WorkBuddy adaptation experience to Codex Desktop

## TL;DR

#63 asked for a WorkBuddy adapter; that work is done on `feat/workbuddy-background`.
Beyond the feature it produced a **method**: measure the layer map, unify CSS at the
**token layer**, allow exactly one alpha per visual group, and pin the result with
machine-checkable invariants. Codex Desktop is beautiCode's reference host, so it
should inherit the method.

**The one conflict that needs your decision:** Codex's CSS contract currently forbids
*"clearing host token surface backgrounds globally"* (`docs/host-adapter.md` →
Forbidden). WorkBuddy wins by doing precisely that — scoped and keyed to the host's own
theme selectors. Porting needs either a controlled exception or an explicit
"Codex stays selector-scoped, coverage stays partial".

---

## 1. What exists today (WorkBuddy, injection-only over CDP, fully reversible)

| File | LOC | Role |
|---|---|---|
| `packages/adapter-workbuddy/src/contract.ts` | 318 | DOM/CSS contract as data: backdrop / surface / flatten / mask selectors, anchors, theme keys |
| `packages/adapter-workbuddy/src/token-overlay.ts` | 398 | Page-side token scan + overlay generator + hard-coded-surface sweep |
| `packages/adapter-workbuddy/src/background-bar.ts` | 614 | Sidebar entry + panel + stage/media runtime (idempotent IIFE) |
| `packages/adapter-workbuddy/src/target.ts` | 98 | Target identification + URL redaction |
| `packages/adapter-workbuddy/src/color.ts`, `host-descriptor.ts` | 78 | Alpha parsing, capability bits |
| `scripts/wb-cdp-runner.mjs` | 747 | Resident daemon: connect → apply → watch → picker bridge |
| `packages/adapter-workbuddy/test/*.test.js` | 371 | 29 unit tests pinning the invariants |

`@beauticode/core` (`ApplyTransaction`, media validation/source, background store, file
lock, error messages, paths) was reused unchanged, and on the Codex side `cdp.ts` +
`injector-lock.ts` carried over as-is — the CDP layer is genuinely host-independent.

## 2. The portable method

**a. Measure, never infer.** Static asar analysis was wrong twice (routing-dependent
subtrees; hashed CSS Module classes). What worked: walk `document.styleSheets` rule by
rule and call `el.matches()` to attribute each background to the exact rule and token,
then tabulate coverage as `element area / viewport area`. WorkBuddy yielded 9 measured
layers, 100% → 6.9%. The numbers, not the selectors, are the durable artifact.

**b. Unify at the token layer.** WorkBuddy paints backgrounds via 2370 rules across 4
token families (`--wb-*`, `--cb-*`, `--cr-*`, `--sk-*`) plus VS Code design tokens
(`--vscode-*`, `--qad-*`, `--ic-*`). Enumerating selectors is hopeless; the host's own
skin system doesn't either. Overriding tokens keyed on the host's theme selectors buys
breadth for free — including pages, modals and dialogs we have never seen. Four
mechanisms with non-overlapping duties: token overlay (breadth), pinned surface rules
(the measured surfaces, derived from **our own** opaque base colour), hard-coded
neutralisation (literal colours no token reaches), and flatten/backdrop/mask/stage.

**c. Mechanisms must never stack on one pixel.** Pinned rules reference no host token, so
a surface covered twice stays `0.82`, not `0.82 × 0.82 ≈ 0.67`.

**d. One alpha per visual group.** Alpha multiplies: container 0.82 + child 0.82 ≈ 0.97
reads as fully solid — the exact cause of the reported "composer is translucent but the
model picker inside it is opaque". Backdrop transparent, floating layers one shared
alpha, inner sub-surfaces flattened, semantic tints (diff add/remove) left opaque.

**e. Invariants as tests** — the real deliverable, since they are what stops a host
update from silently regressing:
1. the alpha set across all translucent elements has size **1**;
2. no element with alpha has an ancestor with alpha;
3. `scrollWidth - innerWidth <= 1`;
4. visibility sampling on an 11×7 grid via `document.elementsFromPoint`, **excluding
   `body`/`html`** (their backgrounds paint below the stage and otherwise yield a false
   "100% occluded");
5. two consecutive applies are idempotent.

## 3. Pitfalls that cost the most time (all user-visible bugs)

1. `calc()` inside `color-mix()` is invalid in Chromium → declaration silently dropped.
   Use a literal percentage.
2. Token overrides **need `!important`**: the host re-declares the same token closer to
   the element, so `html:root` alone reads translucent at the root and solid on the
   composer.
3. Some families are **dark-first** (`--cr-*` declares a dark value at `:root`).
   Bucket declarations into light/dark/neutral by selector intent and resolve
   theme-first; otherwise dark values land on the light theme.
4. Emit **both themes** keyed on the host's own classes — never on "the theme active at
   inject time", which produced white-on-white after switching to dark.
5. Never touch foreground tokens: `--wb-bg-primary-fg` merely contains `bg`; overriding
   it makes text invisible.
6. The scan must skip its own sheets, or a re-apply consumes the overlay it wrote last
   round and drifts.
7. Hard-coded literal surfaces need a **chroma filter** (neutralise near-greys only) or
   buttons, logos, QR codes and the terminal lose their meaning.
8. Read **computed values at the root**, because the semantic layer is almost entirely
   aliases.
9. Style ordering: the host appends sheets at runtime (328 `<head>` children measured,
   97 landing after our first sheet), so at equal specificity the host takes the cascade
   back. **But do not fight another keeper** — WorkBuddy ships a font-size re-sorter and
   two keepers pinning themselves to the end of `<head>` produced measurable 16Hz churn.
   On WorkBuddy our keeper is disabled. **Check whether Codex has one.**
10. A theme switch fires 6+ class changes with an intermediate `theme-switching` state:
    debounce the observer (160 ms) and parse the class **token list**, never compare
    strings.
11. Keep alpha in a CSS variable slot (`var(--bc-surface-alpha-pct, 82%)`) so the opacity
    slider is instant with zero re-injection.
12. Persisted state needs a "blank sample" guard: the daemon polls every 1.5 s, and
    writing a freshly-reloaded page's initial `null`s wipes the user's wallpaper.

## 4. Probes needed before coding (10 minutes each, no guessing)

| # | Question | Decides |
|---|---|---|
| 1 | **Exception for the token-layer route?** (scope it to measured token families and gate on `data-bc-active`) | the whole mechanism — a product decision |
| 2 | Does Codex Desktop ship a `<head>` style re-sorter? | whether the style keeper is ported, adapted or omitted |
| 3 | Codex's token-family layout — how many, any dark-first? | the bucketing logic |
| 4 | Is chat painted in the main renderer or a separate webview/iframe? | CSS cannot cross into a separately-painted webview |
| 5 | Is `file://` direct media reference allowed? | WorkBuddy allows it (6.2 MB verified), removing the inline ceiling and the copy step |

## 5. If accepted

1. `docs/host-adapter.md` updated to describe the token-layer route and its guard rails
   (or to state explicitly that Codex stays selector-scoped).
2. Codex equivalent of `token-overlay.ts` + scan expression (theme bucketing, self-sheet
   skip).
3. Invariants from §2e as unit tests on the Codex side.
4. A committed Codex layer map (coverage + colour source per layer), regenerated on host
   updates.
5. `verify` wired to the existing `ApplyTransaction` rollback path.
6. Regression coverage for the daemon-side behaviours in §3 (blank-sample guard, keeper
   coexistence, theme debounce).
7. A short doc on re-measuring after a Codex update.

## 6. Acceptance criteria

Wallpaper visible under the main surface with visibility sampling ≥ 60% · alpha set has
exactly one value with zero nesting violations · consecutive applies byte-identical ·
theme switch light ↔ dark with no white-on-white and no re-injection · horizontal
overflow ≤ 1 px · `clean` removes every injected node, `data-bc-*` attribute and sheet ·
detector failures fail open and never capture pointer events · no writes anywhere under
the host's own data directory.

## 7. Estimate and risks

Rough split from the WorkBuddy round (working days): probes/layer map ~1, CSS contract +
token overlay ~2, injection runtime and UI ~2, verify/rollback + tests ~1.5,
theme/remount hardening ~1, docs ~0.5.

Risks: **host update drift** (mitigated by structural-anchor self-checks that fail closed
— no anchors, no injection, never a half-apply); **the token-layer exception widening the
maintenance surface** (mitigated by deriving pinned surfaces from our own base colour,
plus the nesting invariant); and **Codex possibly not needing the full method** — even a
partial port pays off, because §2a and §2e transfer regardless of the mechanism chosen.

## 8. References

`docs/host-adapter-workbuddy.md` (full contract: layer table, theme/remount behaviour,
verify criteria, security boundaries, and §15 — a worked example of diagnosing "the model
stopped responding", which turned out to be upstream latency plus a host UI state bug,
**not** the injection) · `docs/host-adapter.md` · `docs/security-boundaries.md` ·
`docs/apply-transaction.md` · #63 · #65.

---

## 中文摘要

把 beautiCode 适配 WorkBuddy 这一轮的经验复用到 Codex Desktop：

1. **方法是实测不是推断**：asar 静态分析错了两次；管用的是遍历 `styleSheets` +
   `el.matches()` 把每个背景归到具体规则与 token，再按「元素面积/视口面积」列分层表
   （WorkBuddy 量出 9 层）。数字才是可延续的产物。
2. **CSS 统一做在 token 层**：2370 条背景规则、4 套 token 家族，逐条枚举不可行；
   覆盖 token 并挂宿主自己的主题选择器，广度免费拿到（连没见过的弹窗一起透）。
3. **两套机制绝不叠加**：钉住的规则用我们自己的不透明基色派生，否则 0.82 × 0.82 ≈ 0.67。
4. **一个分组一个 α**：容器 0.82 + 子元素 0.82 ≈ 0.97，看起来就是实心。
5. **不变量写成测试**（α 集合只有 1 个值、带 α 元素不得有带 α 祖先、横向溢出 ≤1px、
   11×7 可见度抽样要排除 body/html、连续两次 apply 幂等）——这是宿主升级后唯一能挡住
   静默回归的东西。
6. **最花时间的坑**：`color-mix` 里的 `calc()` 被静默丢弃；token 覆盖必须 `!important`；
   `--cr-*` 深色优先会串到浅色主题；`<head>` 末尾顺序被宿主抢回；**但不要跟宿主自己的
   样式看门狗对着干**（两个 keeper 互钉 = 16Hz 抖动，实测过）；主题切换一次 6+ 次 class
   变更，observer 去抖 160ms。
7. **需要维护者先定一件事**：Codex 现行 CSS 契约明确禁止「全局清掉宿主 token 背景」，
   而 token 层正需要它 —— 建议给受控例外（限定实测 token 家族 + `data-bc-active` 门控），
   或明确写「Codex 仍走选择器路线」。另外 4 项（是否有样式看门狗 / token 家族结构 /
   聊天是否在独立 webview / 是否允许 `file://` 直引）用 CDP 各探 10 分钟即可确认。
