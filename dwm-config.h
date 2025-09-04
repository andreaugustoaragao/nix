/* See LICENSE file for copyright and license details. */

#include <X11/XF86keysym.h>

/* appearance */
static const unsigned int borderpx  = 2;        /* border pixel of windows */
static const unsigned int snap      = 32;       /* snap pixel */
static const int showbar            = 1;        /* 0 means no bar */
static const int topbar             = 1;        /* 0 means bottom bar */
static const int usealtbar          = 1;        /* 1 means use non-dwm status bar */
static const char *altbarclass      = "Polybar"; /* Alternate bar class name */
static const char *altbarcmd        = ""; /* Alternate bar launch command - handled by systemd */

static const unsigned int gappx     = 5;        /* gaps between windows */
static const char *fonts[]          = { "CaskaydiaMono Nerd Font:size=11" };
static const char dmenufont[]       = "CaskaydiaMono Nerd Font:size=11";

/* Kanagawa color scheme */
static const char col_bg[]          = "#1f1f28";  /* Kanagawa background */
static const char col_fg[]          = "#dcd7ba";  /* Kanagawa foreground */
static const char col_border_norm[] = "#54546d";  /* Kanagawa comment */
static const char col_border_sel[]  = "#7e9cd8";  /* Kanagawa blue */
static const char col_tag_norm[]    = "#c8c093";  /* Kanagawa light */
static const char col_tag_sel[]     = "#1f1f28";  /* Kanagawa background */
static const char col_tag_bg_sel[]  = "#7e9cd8";  /* Kanagawa blue */
static const char col_status[]      = "#dcd7ba";  /* Kanagawa foreground */

static const char *colors[][3]      = {
	/*               fg           bg            border   */
	[SchemeNorm] = { col_fg,      col_bg,       col_border_norm },
	[SchemeSel]  = { col_tag_sel, col_tag_bg_sel, col_border_sel  },
};

/* tagging */
static const char *tags[] = { "1", "2", "3", "4", "5", "6", "7", "8", "9" };

static const Rule rules[] = {
	/* xprop(1):
	 *	WM_CLASS(STRING) = instance, class
	 *	WM_NAME(STRING) = title
	 */
	/* class      instance    title       tags mask     isfloating   monitor */
	{ "Gimp",     NULL,       NULL,       0,            1,           -1 },
	{ "Firefox",  NULL,       NULL,       1 << 8,       0,           -1 },
};

/* layout(s) */
static const float mfact     = 0.55; /* factor of master area size [0.05..0.95] */
static const int nmaster     = 1;    /* number of clients in master area */
static const int resizehints = 1;    /* 1 means respect size hints in tiled resizals */
static const int lockfullscreen = 1; /* 1 will force focus on the fullscreen window */

static const Layout layouts[] = {
	/* symbol     arrange function */
	{ "[]=",      tile },    /* first entry is default */
	{ "><>",      NULL },    /* no layout function means floating behavior */
	{ "[M]",      monocle },
};

/* key definitions */
#define MODKEY Mod4Mask  /* Super key */
#define TAGKEYS(KEY,TAG) \
	{ MODKEY,                       KEY,      view,           {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask,           KEY,      toggleview,     {.ui = 1 << TAG} }, \
	{ MODKEY|ShiftMask,             KEY,      tag,            {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask|ShiftMask, KEY,      toggletag,      {.ui = 1 << TAG} },

/* helper for spawning shell commands in the pre dwm-5.0 fashion */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static char dmenumon[2] = "0"; /* component of dmenucmd, manipulated in spawn() */
static const char *dmenucmd[] = { "dmenu_run", "-m", dmenumon, "-fn", dmenufont, "-nb", col_bg, "-nf", col_fg, "-sb", col_tag_bg_sel, "-sf", col_tag_sel, NULL };


/* Application commands matching Hyprland config */
static const char *termcmd[]  = { "st", NULL };
static const char *filecmd[]  = { "thunar", NULL };
static const char *browsercmd[] = { "brave", NULL };
static const char *musiccmd[] = { "spotify", NULL };
static const char *nvimcmd[]  = { "st", "-e", "nvim", NULL };
static const char *msgcmd[]   = { "signal-desktop", NULL };
static const char *passcmd[]  = { "bitwarden", NULL };
static const char *grokcmd[]  = { "brave", "--app=https://grok.com", NULL };
static const char *xcmd[]     = { "brave", "--app=https://x.com", NULL };
static const char *btoptcmd[] = { "st", "-e", "btop", NULL };
static const char *menucmd[]  = { "rofi", "-show", "drun", "-theme-str", "* { background: #1f1f28; foreground: #dcd7ba; }", NULL };
static const char *powercmd[] = { "rofi", "-show", "power-menu", "-modi", "power-menu:rofi-power-menu", NULL };

/* Media keys */
static const char *volup[]   = { "pamixer", "-i", "5", NULL };
static const char *voldown[] = { "pamixer", "-d", "5", NULL };
static const char *volmute[] = { "pamixer", "-t", NULL };
static const char *micmute[] = { "pamixer", "--default-source", "-t", NULL };
static const char *brightup[] = { "brightnessctl", "set", "+5%", NULL };
static const char *brightdown[] = { "brightnessctl", "set", "5%-", NULL };

/* Screenshots */
static const char *screenshotsel[] = { "screenshot", NULL };
static const char *screenshottull[] = { "screenshot", "output", NULL };

static Key keys[] = {
	/* modifier                     key        function        argument */
	
	/* Applications (matching Hyprland exactly) */
	{ MODKEY,                       XK_Return, spawn,          {.v = termcmd } },        /* Terminal */
	{ MODKEY,                       XK_f,      spawn,          {.v = filecmd } },        /* File manager */
	{ MODKEY,                       XK_b,      spawn,          {.v = browsercmd } },     /* Browser */
	{ MODKEY,                       XK_m,      spawn,          {.v = musiccmd } },       /* Music */
	{ MODKEY,                       XK_n,      spawn,          {.v = nvimcmd } },        /* Neovim */
	{ MODKEY,                       XK_g,      spawn,          {.v = msgcmd } },         /* Messenger */
	{ MODKEY,                       XK_slash,  spawn,          {.v = passcmd } },        /* Password manager */
	{ MODKEY,                       XK_a,      spawn,          {.v = grokcmd } },        /* Grok AI */
	{ MODKEY,                       XK_x,      spawn,          {.v = xcmd } },           /* X.com */
	{ MODKEY,                       XK_s,      spawn,          {.v = btoptcmd } },       /* System monitor */
	
	/* Menus */
	{ MODKEY,                       XK_space,  spawn,          {.v = menucmd } },        /* Launch apps */
	{ MODKEY|Mod1Mask,              XK_space,  spawn,          {.v = termcmd } },        /* Alt menu (terminal) */
	{ MODKEY,                       XK_Escape, spawn,          {.v = powercmd } },       /* Power menu */
	
	/* Window management (exact Hyprland bindings) */
	{ MODKEY,                       XK_w,      killclient,     {0} },                    /* Close active window */
	{ MODKEY|ShiftMask,             XK_q,      quit,           {0} },                    /* Exit DWM */
	{ MODKEY,                       XK_j,      focusstack,     {.i = +1 } },             /* Focus down */
	{ MODKEY,                       XK_k,      focusstack,     {.i = -1 } },             /* Focus up */
	{ MODKEY,                       XK_h,      setmfact,       {.f = -0.05} },           /* Resize left */
	{ MODKEY,                       XK_l,      setmfact,       {.f = +0.05} },           /* Resize right */
	{ MODKEY,                       XK_v,      togglefloating, {0} },                    /* Toggle floating */
	{ MODKEY,                       XK_p,      incnmaster,     {.i = +1 } },             /* Pseudo (more masters) */
	
	/* Move focus with arrow keys and vim keys */
	{ MODKEY,                       XK_Left,   focusstack,     {.i = -1 } },
	{ MODKEY,                       XK_Right,  focusstack,     {.i = +1 } },
	{ MODKEY,                       XK_Up,     focusstack,     {.i = -1 } },
	{ MODKEY,                       XK_Down,   focusstack,     {.i = +1 } },
	
	/* Switch workspaces with number keys */
	TAGKEYS(                        XK_1,                      0)
	TAGKEYS(                        XK_2,                      1)
	TAGKEYS(                        XK_3,                      2)
	TAGKEYS(                        XK_4,                      3)
	TAGKEYS(                        XK_5,                      4)
	TAGKEYS(                        XK_6,                      5)
	TAGKEYS(                        XK_7,                      6)
	TAGKEYS(                        XK_8,                      7)
	TAGKEYS(                        XK_9,                      8)
	
	/* Tab between workspaces */
	{ MODKEY,                       XK_Tab,    view,           {0} },                    /* Last workspace */
	
	/* Swap windows with vim keys (using zoom to bring to master) */
	{ MODKEY|ShiftMask,             XK_j,      focusstack,     {.i = +1 } },
	{ MODKEY|ShiftMask,             XK_k,      focusstack,     {.i = -1 } },
	{ MODKEY|ShiftMask,             XK_h,      setmfact,       {.f = -0.05} },
	{ MODKEY|ShiftMask,             XK_l,      setmfact,       {.f = +0.05} },
	
	/* Swap windows with arrow keys */
	{ MODKEY|ShiftMask,             XK_Left,   setmfact,       {.f = -0.05} },
	{ MODKEY|ShiftMask,             XK_Right,  setmfact,       {.f = +0.05} },
	{ MODKEY|ShiftMask,             XK_Up,     focusstack,     {.i = -1 } },
	{ MODKEY|ShiftMask,             XK_Down,   focusstack,     {.i = +1 } },
	
	/* Resize windows */
	{ MODKEY,                       XK_minus,  setmfact,       {.f = -0.05} },          /* Expand left */
	{ MODKEY,                       XK_equal,  setmfact,       {.f = +0.05} },          /* Shrink left */
	
	/* Layout switching */
	{ MODKEY,                       XK_t,      setlayout,      {.v = &layouts[0]} },    /* Tiled */
	{ MODKEY|ShiftMask,             XK_f,      setlayout,      {.v = &layouts[1]} },    /* Floating */
	{ MODKEY|ShiftMask,             XK_m,      setlayout,      {.v = &layouts[2]} },    /* Monocle */
	{ ShiftMask,                    XK_F10,    setlayout,      {0} },                   /* Toggle layout (Shift+F10) */
	
	/* Screenshots (Shift+S conflicts with 's', using Print key) */
	{ MODKEY,                       XK_Print,  spawn,          {.v = screenshotsel } },  /* Region screenshot */
	{ MODKEY|ShiftMask,             XK_Print,  spawn,          {.v = screenshottull } }, /* Full screenshot */
	
	/* Media keys */
	{ 0,                            XF86XK_AudioRaiseVolume, spawn, {.v = volup } },
	{ 0,                            XF86XK_AudioLowerVolume, spawn, {.v = voldown } },
	{ 0,                            XF86XK_AudioMute,        spawn, {.v = volmute } },
	{ 0,                            XF86XK_AudioMicMute,     spawn, {.v = micmute } },
	{ 0,                            XF86XK_MonBrightnessUp,  spawn, {.v = brightup } },
	{ 0,                            XF86XK_MonBrightnessDown,spawn, {.v = brightdown } },
};

/* button definitions */
/* click can be ClkTagBar, ClkLtSymbol, ClkStatusText, ClkWinTitle, ClkClientWin, or ClkRootWin */
static Button buttons[] = {
	/* click                event mask      button          function        argument */
	{ ClkLtSymbol,          0,              Button1,        setlayout,      {0} },
	{ ClkLtSymbol,          0,              Button3,        setlayout,      {.v = &layouts[2]} },
	{ ClkWinTitle,          0,              Button2,        zoom,           {0} },
	{ ClkStatusText,        0,              Button2,        spawn,          {.v = termcmd } },
	{ ClkClientWin,         MODKEY,         Button1,        movemouse,      {0} },
	{ ClkClientWin,         MODKEY,         Button2,        togglefloating, {0} },
	{ ClkClientWin,         MODKEY,         Button3,        resizemouse,    {0} },
	{ ClkTagBar,            0,              Button1,        view,           {0} },
	{ ClkTagBar,            0,              Button3,        toggleview,     {0} },
	{ ClkTagBar,            MODKEY,         Button1,        tag,            {0} },
	{ ClkTagBar,            MODKEY,         Button3,        toggletag,      {0} },
};