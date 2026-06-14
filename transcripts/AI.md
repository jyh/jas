Yes, liveness everywhere, like it was built in as a basic concept from the start.

And yes, we want the tool to understand intent, for example cleaning and snapping paths, helping with coloring, assisting with the things that are all obvious. Understanding semantics, for example if I am drawing a block diagram, when I drag a block, the connecting lines come with it. Or if I am drawing a portrait, the tool can help me with proportions, anatomy, coloring. For example if I move the position of one eye, the tool can automatically move the other to match. If I have drawn a figure that is standing, I can easily transform it to reach down and pick a flower. If I have a technical drawing, say of a gear, I can change the number of teeth in the gear in a single step, while also retaining the technical precision.

This will all require deep integrations with AI as an assistant, so that all operations can be performed in a natural way that brings the artist closer to their conception.

For another example, we could imagine an AI-assisted "shaper" where,
- the artist draws freehand, in live mode, where the hand-drawn ink stays on one layer, and the precision layers generates vector paths,
- geometric primitives are inferred from the freehand object,
- the AI assistant helps by projecting a subtle dynamic grid that aligns with the artist's perspective and help them draw

We can imagine the features in this table.

```csv
Feature,Hand-Sketch Action,Technical Output
Line Weights,Varying pressure,"Defined strokes (e.g., 0.25pt for hidden lines, 1pt for outlines)."
Hatching,Quick scribbling in an area,Perfectly spaced vector hatch patterns or architectural fills.
Alignment,Rough stacking,"Instant distribution and ""Tidy Up"" (Vertical/Horizontal centering)."
```

Instead of the very click-heavy manual interface of the classic vector illustration tools, can we get into a more natural flow state, where it would look like a conversation between my hand and the machine. I draw a rough floor plan or a circuit diagram. I don't stop to click "Align" or "Group." I use gestural shortcuts:
- Double-tap a line to see its exact coordinates.
- Flick an element to "Send to Back."
- Lasso a group and pinch to scale them to a specific percentage.

We would like to transform the "slow and detailed" process of the classic vector illustration tools into a performative act with the organic speed of a brainstorm and the "Print-Ready" output of a CAD professional.

You can think of this in some ways as a "Claude Code" but for illustration, where it is not code that we create, but drawing. Where traditional artist skills like, sketching, drawing, painting are all primary and natural but the tool "knows" what I am drawing or painting, and assists me to bring it to life.

Breadth is important too. One project might be a portrait drawing or painting. Another might be an animation. Another might be a brochure with precise professional requirements for type and formatting. Another might be a technical drawing of the gears in a automobile transmission. Another might be a technical diagram of an LLM architecture. And more. In each of these cases we want,

- the distance from concept to creation is short,
- revisions are streamlined, the tool "knows" what I am drawing, so when my client asks for a revision I can do it quickly,
- liveness and non-destructive editing are everywhere,
- tools and panels are important, and give me the deep technical control I need for professional results, but the creation process is natural, and I don't feel burdened by switching tools and panels just so I can get something done.

We want to retain the deep engineering as well.
- 5 apps, so we have the same features everywhere, *and* we improve confidence through cross-app behavioral testing.
- minimizing the amount of manual testing, to the degree possible, because that is the most expensive part of the development.
- reliance on common specification
- high performance and scalable to massive drawings
- clean, factored codebase following good software engineering principles, in all languages
- anticipation that features will grow and change

Please read and understand these requirements. Analyze them for inconsistencies
and completeness. Make suggestions for improvements. Rank your responses in priority
from high to low, and giving each a number. What are the benefits? What are the
downsides? Be ready for a deep dive into any of the suggestions.
