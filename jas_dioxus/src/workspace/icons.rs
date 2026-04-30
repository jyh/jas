//! Toolbar SVG icon generation.

use crate::tools::tool::ToolKind;

/// SVG path data for each tool icon (28x28 viewBox, matching Python toolbar.py).
/// Uses rgb(204,204,204) instead of #ccc to avoid Rust 2021 literal prefix issues.
const IC: &str = "rgb(204,204,204)";

pub fn toolbar_svg_icon(kind: ToolKind) -> String {
    let c = IC;
    match kind {
        // Black arrow with white border
        ToolKind::Selection => r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="black" stroke="white" stroke-width="1"/>"#.to_string(),
        // White arrow with black border
        ToolKind::PartialSelection => r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="white" stroke="black" stroke-width="1"/>"#.to_string(),
        // White arrow with black border + plus badge
        ToolKind::InteriorSelection => r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="white" stroke="black" stroke-width="1"/><line x1="20" y1="20" x2="27" y2="20" stroke="black" stroke-width="1.5"/><line x1="23.5" y1="16.5" x2="23.5" y2="23.5" stroke="black" stroke-width="1.5"/>"#.to_string(),
        // Magic Wand — diagonal handle (lower-left → upper-right) + 4-point
        // sparkle at the tip + a small accent star. Matches the PNG reference
        // at examples/magic-wand.png.
        ToolKind::MagicWand => format!(
            r#"<line x1="4" y1="22" x2="18" y2="8" stroke="{c}" stroke-width="2" stroke-linecap="round"/><polygon fill="{c}" points="20,3 21,7 25,8 21,9 20,13 19,9 15,8 19,7"/><polygon fill="{c}" points="24,12 24.7,13.5 26.5,14 24.7,14.5 24,16 23.3,14.5 21.5,14 23.3,13.5"/>"#),
        // Pen nib (from SVG, scaled from 256x256 viewBox to 28x28)
        ToolKind::Pen => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M163.07,190.51l12.54,19.52-90.68,45.96-12.46-28.05C58.86,195.29,32.68,176.45.13,161.51L0,4.58C0,2.38,2.8-.28,4.11-.37s3.96.45,5.31,1.34l85.42,56.33,48.38,32.15c-7.29,34.58-4.05,71.59,19.86,101.06ZM61.7,49.58L23.48,24.2l42.08,78.11c7.48.17,14.18,2.89,17.49,8.79s3.87,13.16-.95,18.87c-6.36,7.54-17.67,8.57-24.72,3.04-7.83-6.14-9.41-16.13-2.86-24.95L12.09,30.4l.44,69.96-.29,54.31c25.62,11.65,46.88,28.2,61.53,51.84l64.8-33.24c-11.11-25.08-13.69-50.63-8.47-78.19L61.7,49.58Z" fill="rgb(204,204,204)"/><path d="M61.7,49.58l68.41,45.5c-5.22,27.56-2.64,53.1,8.47,78.19l-64.8,33.24c-14.66-23.64-35.91-40.19-61.53-51.84l.29-54.31-.44-69.96,42.43,77.66c-6.55,8.82-4.96,18.8,2.86,24.95,7.05,5.53,18.35,4.49,24.72-3.04,4.82-5.71,4.27-12.96.95-18.87s-10.01-8.62-17.49-8.79L23.48,24.2l38.22,25.38Z" fill="#3c3c3c"/></g>"##.to_string()
        },
        // Add Anchor Point (pen nib + plus sign, from SVG scaled 256→28)
        ToolKind::AddAnchorPoint => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M170.82,209.27l-88.08,46.73-10.99-25.31C60.04,197.72,31.98,175.62.51,162.2L.07,55.68,0,7.02C0,5.03.62,2.32,1.66,1.26S6.93-.46,8.2.39l130.44,88.12c-4.9,32.54-4.3,66.45,14.46,94.39l17.7,26.39Z" fill="rgb(204,204,204)"/><path d="M126.44,94.04c-2.22,11.75-2.88,21.93-2.47,32.64.52,16.1,3.8,30.8,11.11,46.23l-62.86,33.45c-14.38-22.81-34.23-39.94-60.13-51.08l-.62-125.03,41.81,77.76c-5.22,8.02-5.31,16.36.31,22.49,6.1,6.66,15.3,7.1,23.05,1.74,6.57-4.54,7.84-12.25,5.04-18.88s-8.7-11.19-17.14-10.35L22.85,24.63l103.56,69.4Z" fill="#3c3c3c"/><path d="M232.87,153.61c-3.47,3.11-8.74,5.8-13.86,7.8l-18.34-34.03-33.68,18.09-7.64-13.38,34.16-18.2-18.46-35.15,13.59-7.64,18.83,35.42,33.38-17.99,7.32,13.45-33.3,18.14,17.99,33.46Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Anchor Point (pen nib + < chevron, from SVG scaled 256→28)
        ToolKind::AnchorPoint => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M83.11,256l-17.21-39.82c-14.6-25.62-37.76-42.26-64.64-54.74l-.55-51.33L0,6.71C-.02,4.87,1.44,1.8,2.62.77s5.12-1.03,6.66.01l128.83,87.39-2.52,25.97c-2.03,20.93,1.76,44.01,13.52,61.83l21.9,33.2s-87.9,46.83-87.9,46.83Z" fill="rgb(204,204,204)"/><path d="M125.27,93.8L23.13,24.57l39.47,73.45c1.29,2.43,4.09,4.31,6.62,5.06,10.87,1.39,15.9,13.21,12.45,22.55-3.45,9.33-16.08,13.17-24.38,7.8-8.31-5.38-10.28-16.62-3.7-25.38L12.6,30.88l.27,123.04c23.7,11.46,47.42,29.86,60.53,52.12l60.89-32.47c-10.97-26.18-11.95-50.76-9.02-79.77Z" fill="#3c3c3c"/><path d="M179.5,120.04l32.26,60.93-12.56,6.65-39.41-73.7,73.14-38.92c2.57,3.76,4.72,7.63,7.25,12.71l-60.67,32.35h0Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Delete Anchor Point (pen nib + minus sign, from SVG scaled 256→28)
        ToolKind::DeleteAnchorPoint => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M171.16,209.05l-87.84,46.95c-3.95-8.26-7.66-16.33-10.98-24.89-13.5-34.82-37.51-53.77-71.54-69.91l-.4-54.61L0,6.21C0,3.95,2.53.66,4.05.16s4.42.21,6.33,1.51l127.62,86.16c-.17,5.51-.81,10.43-1.56,16.17-3.3,25.08,1.31,50.95,12.81,73.57l21.9,31.48Z" fill="rgb(204,204,204)"/><path d="M126.23,94.28c-1.59,10.88-2.27,20.24-2.17,30.44.4,16.82,3.06,32.72,10.5,48.72l-61.27,32.7c-15.09-22.6-34.96-40.67-60.57-52.09l-.37-123.25,41.01,76.81c-5.22,7.79-5.06,16.71.29,22.63,6.52,7.2,16.36,7.25,24.09,1.18,5.95-4.67,6.35-12.24,4.2-18.37-2.55-7.28-9.14-10.98-17.57-11.7L23.73,25.13l102.5,69.14Z" fill="#3c3c3c"/><rect x="158.95" y="110.41" width="93.43" height="15.36" transform="translate(-31.37 110.38) rotate(-28)" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Pencil (from SVG, scaled from 256→28)
        ToolKind::Pencil => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M57.6,233.77l-51.77,22c-3.79,1.61-6.42-5.57-5.71-8.78l15.63-71.11c1.24-5.63,2.19-9.52,6.08-14.09L108.97,59.4l43.76-50.24c6.91-7.93,20.11-12.57,29.23-6.1,13.11,9.3,24.18,19.89,35.98,30.87,7.38,6.86,8.71,20.57,2.31,28.2l-28.29,33.69-107.57,127.08c-9.12,4.32-17.67,7-26.79,10.88Z" fill="rgb(204,204,204)"/><path d="M208.57,55.33c4.05-7.4-1.19-14.82-6.49-19.18l-25-20.58c-10.66-8.78-22.36,11.05-28.07,18.32,14.44,13.9,28.28,26.73,44.4,38.75,5.64-5.65,11.45-10.55,15.16-17.31Z" fill="#3c3c3c"/><path d="M70.01,189.48c-5.14.35-10.35,1.24-13.94-1.12-2.83-1.86-3.93-9.72-2.84-13.56l101.24-118.96c5.95,4.89,10.67,9.06,15.66,14.57l-100.12,119.07Z" fill="#3c3c3c"/><path d="M47.55,169.12c-3.85,1.45-9.72.32-12.69-2.27l41.55-49.37,32.56-37.99,29.83-34.98c3.62.1,6.99,3.72,8.64,7.09l-45.3,52.97-54.59,64.54Z" fill="#3c3c3c"/><path d="M161.36,111.12l-68.09,80.6c-4.52,5.34-8.33,9.99-13.72,15.13-3.1-3.37-5.1-10.15-1.03-14.97l97.51-115.25c3.44.45,8.52,3.68,8.25,6.56l-22.92,27.94Z" fill="#3c3c3c"/><path d="M71.47,214.03c-11.31,4.52-21.14,8.07-32.31,13.6l-17.23-13.26c.99-5.56,1.35-11.11,2.68-16.6l4.39-18.04c1.63-3.22,11.55-2.19,13.67.71,3.2,4.4,3.19,12.25,7.13,15.82,3.97,3.6,10.62.78,14.92,3.17s4.89,9.2,6.75,14.6Z" fill="white"/></g>"##.to_string()
        },
        // Paintbrush — angled handle + rounded bristled tip, distinct
        // from Pencil's sharp point. Matches PAINTBRUSH_TOOL.md §Tool
        // icon.
        ToolKind::Paintbrush => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M30,230 L60,255 L200,115 L165,80 Z" fill="rgb(204,204,204)"/><rect x="165" y="60" width="45" height="30" transform="rotate(-45, 187, 75)" fill="rgb(100,100,100)"/><path d="M195,45 Q225,20 250,40 Q255,70 225,90 Q200,90 185,65 Z" fill="rgb(204,204,204)"/><path d="M205,55 L225,82 M220,45 L238,70 M235,45 L242,75" stroke="white" stroke-width="4" fill="none" stroke-linecap="round"/></g>"##.to_string()
        },
        // Blob Brush — angled handle + filled blob output below,
        // distinct from Paintbrush's stroke-oriented bristles.
        ToolKind::BlobBrush => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M30,230 L60,255 L200,115 L165,80 Z" fill="rgb(204,204,204)"/><rect x="165" y="60" width="45" height="30" transform="rotate(-45, 187, 75)" fill="rgb(100,100,100)"/><ellipse cx="220" cy="60" rx="40" ry="28" fill="rgb(204,204,204)"/><path d="M50,250 Q80,230 115,240 Q145,255 175,245 Q205,230 225,245 Q245,265 230,250 Q210,235 185,245 Q155,260 125,250 Q90,240 55,260 Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Path Eraser (rotated pencil from SVG, scaled from 256→28)
        ToolKind::PathEraser => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M169.86,33.13L243.34,1.82c3.43-1.46,6.39-2.97,9.92-.52,2.21,1.54,3.34,4.88,2.41,8.76l-19.31,80.53-108.02,125.71-27.98,31.2c-9.63,10.74-24.91,11.34-35.56,1.63l-28-25.52c-9.09-8.28-9.54-23.48-1.42-32.95l40.64-47.45,93.83-110.08Z" fill="rgb(204,204,204)"/><path d="M184.63,65.93c4.88.46,9.96.27,13.5,2.32,2.91,1.68,5.44,10.2,3.01,13.03l-84.89,99c-6.97-3.72-11.86-9.07-15.89-15.76l84.27-98.59Z" fill="#3c3c3c"/><path d="M44.69,212.9c-7.74-11.08,8.68-22.32,17.05-32.78l45.05,40.93-15.82,18.47c-8.77,10.24-21.21-2.39-26.77-7.31-6.96-6.17-14.12-11.58-19.52-19.31Z" fill="#3c3c3c"/><path d="M207.17,85.96c4.81-.22,8.54.77,12.85,3.59l-65.13,76.29-23.35,27c-3.91-1.36-6.44-4.06-8.62-7.89l84.25-98.98Z" fill="#3c3c3c"/><path d="M124.64,106.13l50.36-58.45c2.8,3.96,5.01,9.06,3.33,12.12-5.2,9.48-12.82,16.62-19.83,24.82l-62.56,73.21c-1.99,2.33-5.01,1.06-6.38.14-1.59-1.07-5.25-3.97-3.15-6.5,10.19-12.26,20.7-23.56,30.54-35.78l7.69-9.56Z" fill="#3c3c3c"/><path d="M183.88,41.54c8.08-4.67,16.32-7.31,24.34-10.36,12.84-4.88,5.89-4.25,24.42,10.2,2.91.33-5.31,35.45-6.97,35.87-3.37,3.03-13.57,1.84-14.92-2.22l-4.99-15-16.7-3.81c-4.53-1.03-4.11-9.11-5.17-14.68Z" fill="white"/><rect x="88.74" y="155.97" width="14.58" height="61.84" transform="translate(299.56 239.09) rotate(131.58)" fill="white"/></g>"##.to_string()
        },
        // Smooth tool (pencil with "S" lettering, from SVG scaled 256→28)
        ToolKind::Smooth => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M70.89,227.68L4.52,255.09c-3.64,1.5-5.43-6.66-4.68-9.88l17.55-75.22c7.36-9.61,14.58-17.27,22.29-26.35l91.35-107.59,13.18-14.76c10.19-11.42,24.53-9.65,35.35-.05l25.45,22.59c9.72,8.62,8.08,22.16-.02,31.72l-30.35,35.82-88.63,105.34c-4.48,5.32-8.1,8.07-15.12,10.97Z" fill="rgb(204,204,204)"/><path d="M66.39,191.49c-3.26,3.88-11.08.74-14.17.76-1.6-4.95-2.48-7.92-2.63-12.87l95.93-113.23c5.76,4.1,10.56,8.41,15.29,13.81l-48.81,57.26-45.61,54.27Z" fill="#3c3c3c"/><path d="M194.82,68.3c-4.33,5.25-7.97,9.61-12.6,14.2l-41.17-37.77c6.53-8.97,16.36-26.16,28.28-16.01l23.3,19.83c5.9,5.02,7.29,13.58,2.2,19.76Z" fill="#3c3c3c"/><path d="M32.69,171.62c2.34-2.12,3.21-5.15,5.44-7.75l48.58-56.78,44.96-52.22c3.29,1.06,6.3,3.36,7.96,6.88l-94.82,111.41c-3.41,1.69-7.52.06-12.12-1.54Z" fill="#3c3c3c"/><path d="M74.85,208.97c-1.9-3.51-4.54-7.82-3.2-11.46l62.67-74.53c3.87-4.6,7.33-8.43,11.21-12.99l21.07-24.77c2.92,2.31,5.6,2.99,7.52,5.41-6.28,11.18-14.37,19.01-22.27,28.37l-68.4,80.98c-2.77,3.28-5,5.52-8.61,8.99Z" fill="#3c3c3c"/><path d="M61.28,200.71c2.96,4.4,4.65,9.19,5.65,14.66l-31.21,13.46-15.61-12.98,6.37-34.74c3.86.45,10.27-.54,13.02,2.69,3.65,4.3,2.7,11.09,6.13,15.66,4.75,1.4,9.49.96,15.64,1.26Z" fill="white"/><path d="M210.2,175.94c11.48,9.34,49.63,12.78,45.49,46.07-1.19,9.56-7.61,19.79-18.27,24.04-14.69,5.85-30.81,4.47-45.37-1.23.47-4.68,1.55-7.93,3.11-11.67,9.5,3.79,19.58,5.53,29.64,3.42,8.68-1.82,13.82-8.17,14.43-16.16.65-8.55-3.33-15.19-11.76-19.01l-21.46-9.72c-11.6-5.25-18.43-15.52-18.34-27.89.08-11.69,6.68-22.34,18.54-27.37,14.4-6.11,31.49-4.4,45.49,2.87-.51,4.89-3.12,8.2-4.55,12.47-13.33-8.75-41.32-8.29-43.12,7.75-.73,6.5.91,12.14,6.17,16.42Z" fill="rgb(204,204,204)"/><path d="M183.23,206.16c1.36-3.22,8.17-1.51,11.39-.84,2.35,18.66-5.1,40.07-25.23,43.67-12.58,2.25-25.25-.94-32.47-11.28-6.04-8.66-10.11-20.45-8.36-31.26.55-3.39,10.52-3.41,12.41-.91,2.42,5.85,1.22,13.66,4.25,19.58,3.34,6.52,9.26,10.96,16.14,11.19,7.35.25,13.54-4.25,17.24-10.96,3.2-5.82,2.05-12.38,4.64-19.2Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Type tool — T glyph from assets/icons/type.svg, scaled from 256→28
        ToolKind::Type => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M156.78,197.66l-56.03-.18c-3.93-3.08-4.04-16.09.02-18.64,4.02-2.53,15.24,1.59,16.75-3.47l.29-96.22c-13.59-1.73-25.59-1.5-38.2-.19l-1.84,18.33c-6.36,1.3-11.83,1.26-18.54-.07-.74-13-1.05-25.04.15-38.87h137.24c1.18,13.75.97,25.84.13,38.9-6.65,1.37-12.09,1.27-18.54,0l-1.83-18.28c-12.65-1.26-24.67-1.46-38.15.18v97.73s18.59,1.88,18.59,1.88c1.2,5.78,1.58,10.49-.04,18.91Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Type on a Path tool — from assets/icons/type on a path.svg, scaled from 256→28
        ToolKind::TypeOnPath => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M146.65,143.92c.25,5.89-10.02,3.55-13.5-.15l-17.92-19.02c-3-3.18-.32-7.5,1-9.94,1.7-3.12,8.6,2.51,10.49,1.07,15.2-12.87,29.41-28.44,43.64-43.37,2.98-3.13-2.77-7.24-4.77-8.68-6.3-4.54-20.83,10.64-19.23-6.09.62-6.48,13.52-18.6,20.25-12.75,18.17,15.8,34.79,33.15,50.51,50.94,1.89,6.41-11.7,19.89-18.09,19.49-9.05-.56,2.31-14.04-1.7-19.76-1.73-2.47-7.6-8.13-11.2-4.55l-40.04,39.78.56,13.03Z" fill="rgb(204,204,204)"/><path d="M194,177.67c2.66,10.8-4.29,21.85-11.68,25.96-23.8,13.25-44.93-14.65-61.98-34.74-14.94-17.61-31.47-32.64-47.69-49.18-3.69-3.77-9.56-5.01-13.23-2.97-12.18,6.76-4.54,18.02-13.79,18.91-18.21-.22-2.19-26.12,6.1-28.91,8.07-4.38,20.73-4.56,27.31,1.72,14.67,14.02,28.79,27.1,41.77,42.46,12.68,14.99,26.22,28.37,40.53,41.76,3.82,3.58,10.67,1.41,14.46-.14,4.52-1.84,4.83-8.04,5.72-14.43.45-3.2,11.61-3.95,12.48-.44Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Line segment (from SVG, scaled from 256→28)
        ToolKind::Line => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><line x1="30.79" y1="232.04" x2="231.78" y2="31.05" fill="none" stroke="rgb(204,204,204)" stroke-miterlimit="10" stroke-width="8"/></g>"##.to_string()
        },
        // Rectangle
        ToolKind::Rect => format!(
            r#"<rect x="4" y="4" width="20" height="20" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Rounded Rectangle (from SVG, scaled from 256→28)
        ToolKind::RoundedRect => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><rect x="23.33" y="58.26" width="212.06" height="139.47" rx="30" ry="30" fill="none" stroke="rgb(204,204,204)" stroke-miterlimit="10" stroke-width="8"/></g>"##.to_string()
        },
        // Ellipse (matches workspace/icons.yaml ellipse: rx > ry so
        // it reads as an ellipse, not a circle, at this size).
        ToolKind::Ellipse => format!(
            r#"<ellipse cx="14" cy="14" rx="11" ry="7" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Hexagon (cx=14, cy=14, r=11, 6 sides, -90° start)
        ToolKind::Polygon => format!(
            r#"<path d="M14,3 L23.5,8.5 L23.5,19.5 L14,25 L4.5,19.5 L4.5,8.5 Z" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Star (from SVG, scaled from 256→28)
        ToolKind::Star => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><polygon points="128 50.18 145.47 103.95 202.01 103.95 156.27 137.18 173.74 190.95 128 157.72 82.26 190.95 99.73 137.18 53.99 103.95 110.53 103.95 128 50.18" fill="none" stroke="rgb(204,204,204)" stroke-miterlimit="10" stroke-width="8"/></g>"##.to_string()
        },
        // Lasso (freehand loop — placeholder icon)
        ToolKind::Lasso => format!(
            r#"<path d="M14,5 C6,5 3,10 3,14 C3,20 8,24 14,22 C20,20 22,16 20,12 C18,8 12,9 12,13 C12,16 16,17 17,15" fill="none" stroke="{c}" stroke-width="1.5" stroke-linecap="round"/>"#),
        // Scale — small square being extruded into a larger one
        // (per SCALE_TOOL.md §Tool icon and examples/scale.png).
        ToolKind::Scale => format!(
            r#"<rect x="3" y="13" width="10" height="11" fill="none" stroke="{c}" stroke-width="1.5"/><rect x="13" y="3" width="12" height="13" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Rotate — curved arrow indicating circular motion (per
        // ROTATE_TOOL.md §Tool icon).
        ToolKind::Rotate => format!(
            r#"<path d="M14,5 A9,9 0 1,1 5,14" fill="none" stroke="{c}" stroke-width="1.5" stroke-linecap="round"/><polyline points="11,2 14,5 11,8" fill="none" stroke="{c}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>"#),
        // Shear — square slanted into a parallelogram (per
        // SHEAR_TOOL.md §Tool icon).
        ToolKind::Shear => format!(
            r#"<polygon points="9,4 26,4 19,24 2,24" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Hand — single filled silhouette imported from
        // examples/hand-tool.svg (256x256 source path scaled
        // 28/256 = 0.109375 to fit the toolbar viewBox).
        ToolKind::Hand => format!(
            r##"<g transform="scale(0.109375)"><path d="M0,242.21,201.29,109.51c-38.67,76.35-22.52,97.77-70.85,95.92-17.41-.67-22.83-13.86-33.95-29.17-10.61-14.6-48.58-45.21-35.58-50.06,2.18-.81,7.52-1.22,10.13.03l34.72,16.59c3.14-23.5-23.26-60.36-9.16-70.87,2.27-1.69,10.83,2.29,11.95,5.31l13.71,36.84,2.85-46.1c.18-2.89,3.31-8.22,5.18-9.83,2.35-2.03,11.34,3.32,11.52,6.63l2.8,52.77c13.37-13.74,3.51-35.18,16.16-49.64,2.42-2.77,12.87,3.69,12.5,7.84l-4.82,53.59,19.44-28.39c1.81-2.65,7.35-5.67,10.05-5.82,3.36-.18,5.46,10.22,3.36,14.35Z" fill="{c}"/></g>"##),
        // Zoom — circular lens with a short diagonal handle exiting
        // at lower-right. No interior glyph; the plus / minus appear
        // in the cursor at use time, not the toolbar icon. See
        // ZOOM_TOOL.md §Tool icon.
        ToolKind::Zoom => format!(
            r#"<circle cx="11" cy="11" r="6.5" fill="none" stroke="{c}" stroke-width="2"/><line x1="15.5" y1="15.5" x2="22.5" y2="22.5" stroke="{c}" stroke-width="2.5" stroke-linecap="round"/>"#),
        // Artboard — page rectangle with the upper-right corner
        // folded forward, suggesting "boundary, not content." See
        // ARTBOARD_TOOL.md §Tool icon.
        ToolKind::Artboard => format!(
            r#"<path d="M5,6 L18,6 L23,11 L23,23 L5,23 Z" fill="none" stroke="{c}" stroke-width="2" stroke-linejoin="miter"/><polyline points="18,6 18,11 23,11" fill="none" stroke="{c}" stroke-width="2" stroke-linejoin="miter"/>"#),
        // Eyedropper — squeeze cap (with horizontal grip lines) at
        // upper right, thin glass tube descending at ~45° to a sharp
        // tip at lower left. See EYEDROPPER_TOOL.md §Tool icon.
        // Source path is the 16x16 Bootstrap-icons eyedropper, scaled
        // 1.75x to fill the 28x28 viewBox.
        ToolKind::Eyedropper => format!(
            r##"<g transform="scale(1.75)"><path d="M13.354 2.646a2.121 2.121 0 0 0-3 0l-1.5 1.5-.708-.708a.5.5 0 0 0-.707.708l.353.353-5.146 5.146A1.5 1.5 0 0 0 2.2 10.5L1.5 14a.5.5 0 0 0 .6.6l3.5-.7a1.5 1.5 0 0 0 .854-.44l5.146-5.146.354.354a.5.5 0 0 0 .707-.708l-.707-.707 1.5-1.5a2.121 2.121 0 0 0 0-3.001zM5.39 12.4a.5.5 0 0 1-.285.147L2.65 13.05l.504-2.454a.5.5 0 0 1 .147-.285L8.5 5.111l1.389 1.389z" fill="{c}"/></g>"##),
    }
}
