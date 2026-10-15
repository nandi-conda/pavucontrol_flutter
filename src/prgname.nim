## Names the program before GTK starts (nimkit starts it on import), so the window's WM_CLASS matches the
## desktop entry's StartupWMClass and desktops show the right icon. Import this before nimkit.

proc g_set_prgname(name: cstring) {.importc, cdecl.}

g_set_prgname("dev.v.pavucontrol_flutter")
