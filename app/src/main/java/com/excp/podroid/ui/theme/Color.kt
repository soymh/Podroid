package com.excp.podroid.ui.theme

import androidx.compose.ui.graphics.Color
import com.excp.podroid.BuildConfig

// ── Podroid "Server console" palette ──────────────────────────────────────────
// Dark
val PodroidDarkBg        = Color(0xFF0A0A0A)
val PodroidDarkSurface   = Color(0xFF141414)
val PodroidDarkSurface2  = Color(0xFF1A1A1A)
val PodroidDarkBorder    = Color(0xFF262626)
val PodroidDarkText      = Color(0xFFEDEDED)
val PodroidDarkTextMute  = Color(0xFFA3A3A3)
val PodroidDarkTextFaint = Color(0xFF737373)

// Light
val PodroidLightBg        = Color(0xFFFAFAFA)
val PodroidLightSurface   = Color(0xFFFFFFFF)
val PodroidLightSurface2  = Color(0xFFF4F4F5)
val PodroidLightBorder    = Color(0xFFE4E4E7)
val PodroidLightText      = Color(0xFF0A0A0A)
val PodroidLightTextMute  = Color(0xFF525252)

// Accent (mode-invariant). ArchDroid uses the Arch crystal blue; everything
// else keeps Podroid green. Branched here (instead of a flavor source-set
// override) so exactly one ColorKt exists — no duplicate-class risk.
private val IsArchFlavor = BuildConfig.FLAVOR == "arch"
val PodroidAccent     = if (IsArchFlavor) Color(0xFF1793D1) else Color(0xFF4ADE80)
val PodroidAccentInk  = if (IsArchFlavor) Color(0xFF082F49) else Color(0xFF052E16)
val PodroidAmber      = Color(0xFFF59E0B)
val PodroidRed        = Color(0xFFEF4444)
