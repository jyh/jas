#!/usr/bin/env python3
import subprocess
import sys
import Quartz

def capture_app_window(app_name, output_filename):
    # Fetch all currently on-screen windows (excluding the desktop background)
    window_list = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID
    )

    window_id = None

    # Loop through the windows to find the requested app
    for window in window_list:
        # Get the application owner name (e.g., "Safari", "Calculator")
        owner_name = window.get(Quartz.kCGWindowOwnerName, "")
        
        # We check for layer 0 to avoid grabbing invisible background services
        if app_name.lower() in owner_name.lower() and window.get(Quartz.kCGWindowLayer) == 0:
            window_id = window.get(Quartz.kCGWindowNumber)
            break

    if window_id:
        print(f"Found '{owner_name}' with Window ID: {window_id}")
        
        # Construct and run the native screencapture command
        # Note: macOS requires NO SPACE between the -l flag and the window ID
        cmd = f"screencapture -l{window_id} {output_filename}"
        subprocess.run(cmd, shell=True)
        
        print(f"Success! Screenshot saved to: {output_filename}")
    else:
        print(f"Error: Could not find an open, visible window for '{app_name}'.")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 capture_app.py \"Application Name\" output.png")
        sys.exit(1)
    
    target_app = sys.argv[1]
    output_file = sys.argv[2]
    
    capture_app_window(target_app, output_file)
