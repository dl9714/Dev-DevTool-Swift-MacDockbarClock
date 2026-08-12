#!/usr/bin/env python3
import datetime as dt
import tkinter as tk


WIDTH = 190
HEIGHT = 60
MARGIN_RIGHT = 18
DOCK_GAP = 92
BG = "#111317"
FG_TIME = "#f5f7fb"
FG_DATE = "#aeb6c2"
ACCENT = "#4f9bff"


class DockClock:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("Dock Clock")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", 0.94)
        self.root.configure(bg=BG)
        self.show_seconds = False
        self.drag_start = None

        self.canvas = tk.Canvas(
            self.root,
            width=WIDTH,
            height=HEIGHT,
            bg=BG,
            highlightthickness=1,
            highlightbackground="#303744",
            bd=0,
        )
        self.canvas.pack(fill="both", expand=True)
        self.canvas.create_rectangle(0, 9, 3, 51, fill=ACCENT, width=0, tags="static")

        for widget in (self.root, self.canvas):
            widget.bind("<ButtonPress-1>", self.start_drag)
            widget.bind("<B1-Motion>", self.drag)
            widget.bind("<Double-Button-1>", self.toggle_seconds)
            widget.bind("<Button-2>", self.quit)
            widget.bind("<Button-3>", self.quit)
            widget.bind("<Control-Button-1>", self.quit)

        self.position_near_dock()
        self.update_clock()

    def position_near_dock(self) -> None:
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        x = screen_w - WIDTH - MARGIN_RIGHT
        y = screen_h - HEIGHT - DOCK_GAP
        self.root.geometry(f"{WIDTH}x{HEIGHT}+{x}+{y}")

    def update_clock(self) -> None:
        now = dt.datetime.now()
        time_fmt = "%H:%M:%S" if self.show_seconds else "%H:%M"
        self.canvas.delete("clock")
        self.canvas.create_text(
            WIDTH - 14,
            22,
            text=now.strftime(time_fmt),
            fill=FG_TIME,
            font=("Helvetica Neue", 25, "bold"),
            anchor="e",
            tags="clock",
        )
        self.canvas.create_text(
            WIDTH - 15,
            45,
            text=now.strftime("%a, %Y.%m.%d"),
            fill=FG_DATE,
            font=("Helvetica Neue", 11),
            anchor="e",
            tags="clock",
        )
        delay = 250 if self.show_seconds else 1000
        self.root.after(delay, self.update_clock)

    def start_drag(self, event) -> None:
        self.drag_start = (event.x_root, event.y_root, self.root.winfo_x(), self.root.winfo_y())

    def drag(self, event) -> None:
        if not self.drag_start:
            return
        start_x, start_y, win_x, win_y = self.drag_start
        dx = event.x_root - start_x
        dy = event.y_root - start_y
        self.root.geometry(f"{WIDTH}x{HEIGHT}+{win_x + dx}+{win_y + dy}")

    def toggle_seconds(self, _event=None) -> None:
        self.show_seconds = not self.show_seconds

    def quit(self, _event=None) -> None:
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


if __name__ == "__main__":
    DockClock().run()
