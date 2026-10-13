import Foundation

/// Cutline's Manim program for templates. It's fixed: what the user types reaches it only
/// as data (CUTLINE_PARAMETERS → "settings"), so no text can turn into code.
nonisolated enum TemplateProgram {
    static let scene = "CutlineTemplate"

    static let script = #"""
from manim import *
import json, os

P = json.loads(json.load(open(os.environ["CUTLINE_PARAMETERS"]))["settings"])
FW, FH = config.frame_width, config.frame_height
UNIT = FH / 1080                 # Manim units per pixel at 1080p
FONT = 0.52                      # Manim font_size per pixel of Cutline text size

def c(h): return ManimColor(h)

def text(s, size, color=None, italic=None, weight=None):
    kw = dict(font=P["family"], font_size=max(size * FONT, 1), weight=weight or P["weight"])
    if italic if italic is not None else P["italic"]:
        kw["slant"] = ITALIC
    if P["gradient"] and color is None:
        t = Text(s, gradient=(c(P["color"]), c(P["gradient"])), **kw)
    else:
        t = Text(s, color=c(color or P["color"]), **kw)
    return outline(t, size / max(P["size"], 1))

def outline(m, scale=1.0):
    # The outline follows the text's size: smaller lines (subtitles) get a thinner one.
    if P["outlineWidth"] > 0:
        m.set_stroke(c(P["outlineColor"]), width=P["outlineWidth"] * 2 * min(scale, 1.0), background=True)
    return m

def panel(group, pad=0.35, radius=0.18, color=None, opacity=None):
    box = RoundedRectangle(corner_radius=radius, width=group.width + pad * 2, height=group.height + pad * 2)
    box.set_fill(c(color or P["panelColor"]), opacity=P["panelOpacity"] if opacity is None else opacity).set_stroke(width=0)
    box.move_to(group)
    return VGroup(box, group)

def place(m):
    m.move_to([(P["x"] - 0.5) * FW, (0.5 - P["y"]) * FH, 0])
    return m

def build():
    t, size = P["template"], P["size"]
    if t == "title":
        main = text(P["text"], size)
        group = VGroup(main, text(P["secondary"], size * 0.42)).arrange(DOWN, buff=0.25) if P["secondary"].strip() else VGroup(main)
    elif t == "lowerThird":
        group = VGroup(text(P["text"], size), text(P["secondary"], size * 0.55, weight="NORMAL")).arrange(DOWN, aligned_edge=LEFT, buff=0.15) \
            if P["secondary"].strip() else VGroup(text(P["text"], size))
    elif t == "scoreBug":
        score = text(P["extra"] or "0 – 0", size)
        group = VGroup(text(P["text"], size), panel(VGroup(score), pad=0.18, color=P["color"], opacity=0.0), text(P["secondary"], size)).arrange(RIGHT, buff=0.45)
    elif t == "quote":
        quote = text("“" + P["text"] + "”", size)
        if quote.width > FW * 0.85:
            quote.scale_to_fit_width(FW * 0.85)
        group = VGroup(quote, text("— " + P["secondary"], size * 0.5, italic=False)).arrange(DOWN, aligned_edge=RIGHT, buff=0.3) \
            if P["secondary"].strip() else VGroup(quote)
    elif t == "equation":
        eq = MathTex(P["text"], color=c(P["color"]), font_size=max(size * FONT * 1.3, 1))
        group = VGroup(outline(eq))
    elif t == "callToAction":
        button = text(P["text"], size)
        group = VGroup(panel(VGroup(button), pad=0.4, radius=(button.height + 0.8) / 2))
        if P["secondary"].strip():
            group = VGroup(group, text(P["secondary"], size * 0.45)).arrange(DOWN, buff=0.3)
        return place(group)
    else:
        group = VGroup(text(P["text"], size))
    if P["panel"]:
        group = panel(group)
    return place(group)

def enter(m):
    kind, lag, run = P["in"], P["lag"], P["inTime"]
    shift = {"slideRight": RIGHT, "slideLeft": LEFT, "slideUp": UP, "slideDown": DOWN}
    if kind == "write":
        return Write(m, run_time=run, lag_ratio=max(lag, 0.01))
    if kind == "typewriter":
        letters = [x for x in m.family_members_with_points() if not isinstance(x, (RoundedRectangle, Rectangle))]
        return LaggedStart(*[FadeIn(x, run_time=0.01) for x in letters], lag_ratio=1, run_time=run) if letters else FadeIn(m, run_time=run)
    if kind in shift:
        base = lambda x: FadeIn(x, shift=shift[kind] * 1.5)
    elif kind == "grow":
        base = lambda x: GrowFromCenter(x)
    elif kind == "pop":
        base = lambda x: FadeIn(x, scale=0.3)
    elif kind == "spin":
        return SpinInFromNothing(m, run_time=run)
    elif kind == "draw":
        return DrawBorderThenFill(m, run_time=run)
    else:
        base = lambda x: FadeIn(x)
    if lag > 0.01 and len(m.submobjects) > 0:
        parts = m.family_members_with_points()
        return LaggedStart(*[base(x) for x in parts], lag_ratio=lag * 0.15, run_time=run)
    return base(m) if run <= 0 else AnimationGroup(base(m), run_time=run)

def leave(m):
    kind, run = P["out"], P["outTime"]
    shift = {"slideLeft": LEFT, "slideRight": RIGHT, "slideUp": UP, "slideDown": DOWN}
    if kind in shift:
        return FadeOut(m, shift=shift[kind] * 1.5, run_time=run)
    if kind == "shrink":
        return ShrinkToCenter(m, run_time=run)
    if kind == "unwrite":
        return Unwrite(m, run_time=run)
    return FadeOut(m, run_time=run)

class CutlineTemplate(Scene):
    def still(self, m, seconds):
        # A live do-nothing animation: Manim writes no PNG frames for wait() when nothing
        # moves, which would cut the hold out of the movie.
        if seconds > 0.01:
            self.play(UpdateFromFunc(m, lambda x: x), run_time=seconds)

    def hold(self, m, seconds):
        kind = P["during"]
        if seconds <= 0.05:
            return
        if kind == "pulse":
            beats = max(int(seconds // 0.8), 1)
            for _ in range(beats):
                self.play(m.animate.scale(1.06), rate_func=there_and_back, run_time=seconds / beats)
        elif kind == "wiggle":
            self.play(Wiggle(m, run_time=min(seconds, 1.2)))
            self.still(m, seconds - 1.2)
        elif kind == "wave":
            self.play(ApplyWave(m, run_time=min(seconds, 1.5)))
            self.still(m, seconds - 1.5)
        elif kind == "flash":
            accent = P["gradient"] or "#FFD23F"
            self.play(Indicate(m, color=c(accent), scale_factor=1.05, run_time=min(seconds, 1.0)))
            self.still(m, seconds - 1.0)
        else:
            self.still(m, seconds)

    def construct(self):
        t = P["template"]
        if t == "countdown":
            for n in range(max(int(P["countdownFrom"]), 0), 0, -1):
                number = place(text(str(n), P["size"]))
                self.play(FadeIn(number, scale=0.4), run_time=0.25)
                self.still(number, 0.5)
                self.play(FadeOut(number, scale=1.6), run_time=0.25)
        if t == "counter":
            value = ValueTracker(P["countFrom"])
            decimals = int(P["decimals"])
            def label():
                number = f"{value.get_value():,.{decimals}f}"
                parts = VGroup(text(number, P["size"]))
                if P["text"].strip():
                    parts = VGroup(parts[0], text(P["text"], P["size"] * 0.4)).arrange(DOWN, buff=0.2)
                if P["panel"]:
                    parts = panel(parts)
                return place(parts)
            shown = label()
            self.play(enter(shown))
            # The entrance may have added the pieces one by one: clear them all.
            self.remove(*self.mobjects)
            live = always_redraw(label)
            self.add(live)
            self.play(value.animate.set_value(P["countTo"]), run_time=max(P["hold"], 0.1), rate_func=smooth)
            live.clear_updaters()
            if P["out"] != "none":
                self.play(leave(live))
            return
        m = build()
        self.play(enter(m))
        self.hold(m, P["hold"])
        if P["out"] != "none":
            self.play(leave(m))
"""#
}
