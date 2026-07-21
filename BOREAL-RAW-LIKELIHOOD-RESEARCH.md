# The Nature of the DNG — verified research survey

> Deep-research sweep 2026-07-19: 5 angles, 22 sources, 108 claims
> extracted, top 25 adversarially verified (3-vote panels): 23
> confirmed, 2 refuted. Plus a LOCAL empirical section (§7) measured
> on Daniel's own iPhone 17 Pro DNGs the same day. Note: several
> verification legs ran without the safety-review model; every claim
> below was cross-checked against the local measurements and standard
> published physics before inclusion.
>
> THE POINT (Daniel's framing, confirmed by the math): a DNG sample
> is not a pixel — it is a DRAW from a distribution whose parameters
> are the capture parameters. The gradient of that distribution's
> log-likelihood is the gradient descent the model should encode.

## 1. What a raw DN is  [3-0 ×6 merged]

The canonical model (Foi et al., IEEE TIP 17(10), 2008; independently
PoGaIN 2022, Fossum photon-transfer 2016, SNIC 2025 — identical laws):

    z = y + σ(y)·ξ,     var(z) = a·y + b        (the AFFINE law)

Poisson photon counting (variance = mean, in electrons) through a
gain, plus signal-independent Gaussian read noise. In DN units per
CFA channel this is exactly

    var(DN) = a·(DN − black) + b

Sources: webpages.tuni.fi/foi/papers/Foi-PoissonianGaussianClippedRaw-2007-IEEE_TIP.pdf ·
ieeexplore.ieee.org/document/4623175 · arxiv.org/pdf/2210.04866 ·
ericfossum.com JEDS 2016 · arxiv.org/abs/2512.15905

## 2. How the capture parameters enter  [3-0 ×3 merged]

With conversion constant χ, analog gain θ (what ISO controls), and
pedestal p₀ (Foi §II, verbatim):

    a = χ⁻¹·θ
    b = θ²·var(pre-amp read) + var(post-amp/ADC) − θ²·χ⁻¹·p₀

- **a ∝ ISO** (linearly); pre-amp read noise in b scales as **θ²**;
  post-amp/ADC noise doesn't scale at all.
- **Exposure time and ISO are asymmetric**: exposure raises y BEFORE
  amplification (real photons — SNR improves as √t); ISO multiplies
  AFTER (no new photons — SNR at fixed brightness gets worse). This
  asymmetry is the whole reason bracketing works.
- b can be legitimately NEGATIVE (large pedestal, small read noise)
  while a·y + b ≥ 0 always holds.
- Caveat (verified): dual conversion gain and extended-ISO digital
  gain bend the clean scalings — **fit per ISO, never extrapolate**.
  (§7: the iPhone 17 Pro visibly does this at ISO 1250.)

## 3. The rails: pedestal and censoring  [3-0 ×3 each]

- **Black level 528 is a pedestal, and statistics below it are real
  signal.** The DNG spec's own processing model says to preserve
  negative post-black values in early stages for better shadow
  processing. ⚠ BOREAL FINDING: `normalizeMosaic` clamps at 0 (the
  CQ6 `max(…, 0)`) — this censors the read-noise lower tail and
  biases shadow means UP. Whether to lift the clamp is a spec
  decision (ownedCbrt already handles negatives by odd symmetry);
  registered as a proposed law change, Daniel's call.
- **White 4095 is censoring, not truncation** (Foi 2008 §IV; Foi
  2009 Signal Processing 89(12)): a clipped pixel contributes
  P(z ≥ white | μ) to the likelihood, not a Gaussian residual; the
  var-vs-mean curve bends near both rails. Fuse/loss must ZERO or
  censor clipped samples — never treat 4095 as a value.

## 4. The likelihood, exactly and approximately  [3-0 ×3 merged]

Exact per-pixel likelihood = a Poisson-weighted infinite mixture of
Gaussians (Fossum 2016 Eq. 1 / PoGaIN Eq. 5) — correct but
impractical. The standard, justified shortcut: P(λ) ≈ N(λ, λ), under
which the log-likelihood is Gaussian NLL with variance a·μ + b and

    score = ∂/∂μ log L = (x − μ) / var(μ)

**This is the theorem Daniel asked the loss to encode: a
variance-weighted L2 / Gaussian-NLL on raw DNs, with w = 1/(a·μ + b)
and censored rails, IS gradient descent on the physical likelihood.**
Every heuristic BOREAL replaces with this stops being a choice and
becomes the sensor's own geometry.

## 5. The DNG spec carries the model  [3-0 ×2 merged]

Tag 51041 **NoiseProfile**: N(x) = √(S·x + O) on the NORMALIZED
signal x ∈ [0,1]; S = gain, O = read variance; 2 values or 2 per CFA
plane. DN conversion with D = white − black = 3567:

    var(DN) = S·D·(DN − 528) + O·D²

What phones actually write [3-0; accuracy sub-claim refuted 1-2]:
one (S, O) pair for all four channels, and the tag does NOT record
the ISO it applies to — a real spec weakness. BUT (local, §7): Apple
writes the tag PER CAPTURE, and BOREAL's bracket has per-frame EXIF
ISO — so the pairing is recoverable frame by frame. The refuted
claim ("smartphone NoiseProfile systematically wrong due to
pre-DNG smoothing") survived 1-2, i.e. genuinely uncertain: validate
Apple's tag against self-calibration (§7 does, partially).

## 6. MLE fusion of the bracket (D11's answer)  [3-0 + synthesis]

Hasinoff/Durand/Freeman ICCV 2010: noise-optimal HDR = inverse-
variance weighting of per-frame radiance estimates (the MLE for
heteroscedastic Gaussians), clipped samples censored; and optimal
capture spends budget on the darks at high ISO (gain lifts signal +
shot noise above the POST-amp read floor — "the high-ISO advantage").
For the 1/4/16/64 bracket:

    ŷᵢ = (DNᵢ − 528) / (gᵢ·tᵢ)          per-frame radiance estimate
    wᵢ = 1 / var(ŷᵢ)                     var from §2 propagated
    ŷ  = Σ wᵢ·ŷᵢ / Σ wᵢ,  wᵢ = 0 when clipped

⚠ BOREAL FINDING: the current fuse's knee/clip blend (0.90/0.98) is
a heuristic standing where the MLE weights should be — D11 (open
since the signal-ladder sweep) now has its literature answer. The
exact Hasinoff weight formulas did not survive verification verbatim
(single-source; synthesis above is from verified principles) — pull
the paper before landing the law. Iterative discipline: the fuse is
golden-gated; the MLE fuse lands as a spec'd revision, not a hot swap.

## 7. LOCAL EVIDENCE (measured 2026-07-19, Daniel's 4 DNGs)

**Apple writes NoiseProfile + BaselineExposure per frame** (probed
tags, frame 1 vs 4):

    frame 1 (ISO 100):  NoiseProfile S=1.336e-4  O=9.79e-7   BaselineExposure 0.854
    frame 4 (ISO 1250): NoiseProfile S=5.425e-4  O=1.31e-6   BaselineExposure 1.638

S ratio 4.06 over an ISO ratio 12.5 — Apple's own tag encodes the
**dual-conversion-gain break** §2's caveat predicts.

**Measured mean-variance (single-phase green, 32² blocks, p10
low-envelope), two estimators:**

    method                     f1 (ISO100)      f2      f3      f4 (ISO1250)
    block variance             a=0.469          1.21    4.04    8.86  ← texture-contaminated (∝μ²): convex, b<0
    2nd differences (1-2-1)    a=0.271          0.579   1.256   1.552
      a per 100 ISO            0.271            0.289   0.251   0.124 ← ∝ISO thru 500; DCG break at 1250
    NoiseProfile (tag → DN)    a=0.477 b=12.5   —       —       a=1.935 b=16.7

Readings:
- The AFFINE FORM and a ∝ ISO hold through ISO 500 on real photons;
  the ISO-1250 break matches the tag's own break. b grows 1.5 → 258
  DN² (θ² read-noise amplification, §2).
- **Estimator epistemology**: block variance over-reads (scene
  texture ∝ μ²; frame 1 only looked clean because it is dark);
  second differences under-read when neighbor noise is correlated
  (0.57× of the tag at ISO 100). The calibrated tag sits between the
  two biases. Burst/motion estimation produced NO surviving claims
  in the sweep (part 4 unanswered in literature) — consistent with
  the T1b handheld finding (ĝ reads the temporal floor, ~1000× shot
  noise, under global tremor).
- **Resolution for T1b: the tag IS the noise model; temporal
  statistics VALIDATE it** (a law: tag-predicted n̂ vs σ_time-quiet
  bins within a window), instead of estimating what the maker
  already calibrated.

## 8. What BOREAL encodes (the actionable ledger)

1. **Decoder**: read NoiseProfile (51041) + BaselineExposure (50730)
   into Frame — per-frame calibrated (a, b). [small, additive]
2. **T3 loss**: w = 1/(a·μ + b) per sample (DN domain, per frame),
   censored at the rails — the NN's loss becomes the physical score.
   Synth must inject noise FROM the tag model at post-bin level
   (BC boundary + this doc, one policy).
3. **D11**: MLE fuse weights (§6) as a spec'd revision of the
   knee/clip fuse; judged against the current fuse on report bundles
   before promotion.
4. **T1b**: tag-as-model + temporal-validation law (TB extension) —
   closes the handheld ĝ question honestly.
5. **Sub-black clamp**: registered censoring bias in normalizeMosaic
   (§3) — Daniel decides whether shadows go negative-preserving.
6. **ETTR planner**: the high-ISO advantage (§6) is a direct input
   to the EvPlan laws — budget toward darks at gain is optimal
   under the same variance model the planner already serves.

## Open questions (carried)

1. iPhone 17 Pro NoiseProfile vs full self-calibrated PTC across the
   ISO range (§7 covers 4 points, one scene; a flat-field PTC session
   would settle the 0.57×–1.0× estimator gap and the refuted-but-
   uncertain accuracy claim).
2. Hasinoff's exact weight/allocation formulas + the when-to-saturate
   condition, specialized to the fixed 1/4/16/64 bracket.
3. Burst noise estimation under motion — no literature survived; the
   σ_time-quiet-bin approach is BOREAL's own ground.
4. iPhone 17 Pro unity-gain ISO / conversion gain / DCG mode map —
   determines b(ISO) structure between the bracket's ISO points.

## Refuted during verification

- "Smartphone NoiseProfile systematically inaccurate due to pre-DNG
  content-aware smoothing" (1-2 — uncertain, not established; hence
  the validation law rather than blind trust).
- One duplicate ISO-gain claim (0-3 on sourcing; identical physics
  passed 3-0 from the primary PDF).
