# Requirements

The software must be built as a vector-based environment where all visual elements are defined by mathematical paths rather than pixels. This architecture ensures "resolution independence," allowing designs to scale from business cards to billboards without loss of quality .

### **Objectives of the Creative Professional**

The primary goal of the professional user is to move a design from initial concept to completion, often involving peer collaboration and client feedback. Key objectives include:

* **Workflow Efficiency:** Utilizing keyboard shortcuts and customized workspaces to accelerate repetitive tasks.  
* **Organization:** Maintaining logical structures through layers, groups, and artboards to manage complex illustrations efficiently .  
* **Precision:** Using grids, guides, and snapping tools to ensure mathematical exactness in layouts .  
* **Professional Output:** Delivering high-quality content in various formats suitable for mobile, web, print, film, and video .

---

### **User Interface Architecture**

The GUI must be highly customizable, allowing users to reconfigure it for specific tasks or comfort .

#### **1\. Primary Windows and Navigation**

* **Home Screen:** Upon launch, users are greeted with a welcome screen to create new files, open recent ones, or access tutorials.  
* **New Document Dialog:** Allows users to choose presets based on intended output (Print, Web, Mobile, Film & Video, Art & Illustration) or use templates .  
* **Application Bar:** Located at the top right, providing access to the Workspace menu and document sharing options.  
* **Workspaces:** Predefined or custom layouts of panels. Standard workspaces include Essentials (default), Layout, Typography, Painting, and Web .

#### **2\. Toolbars and Panels**

* **Main Toolbar:** Usually located on the left; contains tools for selection, drawing, and transformation.  
* **The Dock:** A vertical arrangement on the right where panels and panel groups are collected.  
* **Properties Panel:** A context-sensitive "one-stop shop" that changes based on what is selected, offering quick access to Transforms, Appearance, Alignments, and Quick Actions .  
* **Control Panel:** Located below the application bar, it offers extensive visuals and choices for object attributes like Fill, Stroke, and alignment .  
* **Appearance Panel:** Tracks all attributes (fills, strokes, opacity, blending modes) and effects applied to a selected object .

---

### **Core Functional Concepts**

#### **1\. Structural Elements**

* **Artboards:** The "pages" of the document. A single file can host multiple artboards of different sizes and orientations (Portrait or Landscape).  
  * **Video Safe Areas:** Optional green guides for video content creation, including Title Safe and Action Safe areas .  
* **Layers:** A hierarchy used to separate design parts, functioning like a stack of transparent sheets.  
  * **Template Layers:** Locked and dimmed layers (often 50% opacity by default) used for tracing over sketches or raster images .  
* **Groups:** Binding two or more objects together to move or scale as one unit.  
  * **Sublayers/Nested Groups:** Creating groups within groups to manage details of a larger object.  
* **Isolation Mode:** A view that dims everything else to allow for the editing of a specific group or sublayer without interference.

#### **2\. Path Anatomy and Objects**

* **Anchor Points:** The "dots" defining where a line starts, stops, or turns.  
* **Segments:** The lines or curves connecting anchor points.  
* **Handles (Direction Lines):** "Pull tabs" on anchor points used to adjust the angle and depth of curved segments.  
* **Open vs. Closed Paths:** Open paths are lines (e.g., "U"), while closed paths form complete shapes (e.g., "O").

#### **3\. Appearance and Styling**

* **Fill:** The color, gradient, or pattern inside a closed path.  
* **Stroke:** The outline or border. Attributes include weight (thickness), alignment (Center, Inside, Outside), and variable width profiles.  
* **Blending Modes and Opacity:** Control how an object’s color interacts with objects underneath (e.g., Multiply, Screen) and its level of transparency.

---

### **Functional Tools and Operations**

#### **1\. Essential Drawing Tools**

* **Pen Tool (P):** Creates paths with straight or curved segments with maximum flexibility .  
* **Curvature Tool (Shift \+ \~):** A more intuitive path-creation tool that allows users to preview and edit smooth curves as they draw.  
* **Pencil Tool (N):** Draws freehand vector paths that can be redrawn or smoothed using the Smooth Tool.  
* **Paintbrush (B) & Blob Brush (Shift \+ B):** The Paintbrush applies stylistic brush profiles to a path, while the Blob Brush creates a filled vector shape around the painted area.  
* **Shape Tools:** Standard tools for Rectangles, Ellipses, Polygons, and Stars .

#### **2\. Path Operations and Manipulation**

* **Pathfinder:** A panel for combining, subtracting, or intersecting multiple shapes. Specific modes include Unite, Minus Front, Intersect, Exclude, and Divide .  
* **Shape Builder Tool (Shift \+ M):** Allows users to merge or subtract overlapping areas by simply drawing a line across them .  
* **Clipping Masks:** Using one shape (the mask) to hide parts of underlying objects.  
* **Compound Paths (Ctrl \+ 8):** Combining objects so that overlapping areas create holes (e.g., a donut shape).

#### **3\. Transformations**

Objects can be manipulated via the Transform menu or bounding box handles.

* **Move:** Precise measurement of movement.  
* **Rotate:** Tilting an object to a specific angle.  
* **Reflect:** Mirroring an object horizontally or vertically.  
* **Scale:** Adjusting size while optionally scaling strokes and effects.  
* **Shear:** Sliding selected objects at a chosen angle.

---

### **Typography and Asset Management**

* **Type Tools:** Support for Point Type (headlines), Area Type (paragraph containers), and Type on a Path.  
* **Character and Paragraph Panels:** Deep control over fonts, styles, kerning, tracking, leading, and justification .  
* **Symbols:** Reusable design elements. **Dynamic Symbols** allow editing a master symbol to update all instances or adjusting individual instances independently.  
* **Asset Export:** A panel dedicated to saving independent elements or entire artboards for use in other projects or platforms.