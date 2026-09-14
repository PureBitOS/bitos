; BitOS — stock wallpaper embedded (1024x768 XRGB32, from stockwallpaper.png).
section .rodata
global wallpaper_data, wallpaper_end
wallpaper_data:
incbin "wallpaper.raw"
wallpaper_end:
