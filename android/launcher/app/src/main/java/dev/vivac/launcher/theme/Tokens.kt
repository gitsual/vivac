package dev.vivac.launcher.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.R

/**
 * Vivac tokens, "la noche en la pared". Brand values come from theme.conf
 * (Bad Romance · Nocturne); semantic names below are what the screens use.
 */
object Brand {
    val noche950 = Color(0xFF18131B)
    val noche900 = Color(0xFF2D1F2D)
    val noche850 = Color(0xFF362836)
    val noche800 = Color(0xFF43363F)
    val noche500 = Color(0xFF9A7F8C)
    val papel50 = Color(0xFFF4E9D0)
    val papel100 = Color(0xFFE8D5AB)
    val papel300 = Color(0xFFC0AD95)
    val papel500 = Color(0xFF979367)
    val frontal300 = Color(0xFFF0A3A6)
    val frontal400 = Color(0xFFE1777D)
    val glaciar400 = Color(0xFF6CA4B1)
    val cima = Color(0xFF55A185)
    val cimaSubtle = Color(0xFFCFEBDD)
}

object Ink {
    val surface = Brand.noche900
    val raised = Brand.noche850
    val field = Brand.noche800
    val deep = Brand.noche950
    val text = Brand.papel100
    val textMuted = Brand.papel300
    val contour = Brand.noche850
    /** Control borders: noche 500, since noche 600 only reaches 2.79:1 on the surface. */
    val borderControl = Brand.noche500
    val primary = Brand.frontal400
    val onPrimary = Brand.noche900
    val accentText = Brand.frontal300
    /** Glaciar is for measures only (progress, figures), never for actions. */
    val measure = Brand.glaciar400
    val ok = Brand.cima
    val okText = Brand.cimaSubtle

    /**
     * Monogram colours for Petate tiles on noche 800 (measured): papel 100 7.91, frontal 300 5.71,
     * glaciar 300 5.70, cima 300 5.36, papel 300 5.25, papel 50 9.47. Glaciar 400 (4.13) and cima (3.71) fail there.
     */
    val tileTones = listOf(Brand.papel100, Brand.frontal300, Color(0xFF8FBFCA), Color(0xFF7DBFA3), Brand.papel300, Brand.papel50)
}

@OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
private fun variable(res: Int, weight: Int) =
    Font(res, FontWeight(weight), variationSettings = FontVariation.Settings(FontVariation.weight(weight)))

object Faces {
    /** Display face: titles and big figures only. */
    val unbounded = FontFamily(variable(R.font.unbounded, 700), variable(R.font.unbounded, 800))
    val grotesk = FontFamily(variable(R.font.space_grotesk, 400), variable(R.font.space_grotesk, 500), variable(R.font.space_grotesk, 700))
    val mono = FontFamily(variable(R.font.jetbrains_mono, 400), variable(R.font.jetbrains_mono, 500))
}

object Type {
    val title = TextStyle(fontFamily = Faces.unbounded, fontWeight = FontWeight.ExtraBold, fontSize = 34.sp, lineHeight = 40.sp, letterSpacing = (-0.02).em, color = Ink.text)
    val figure = TextStyle(fontFamily = Faces.unbounded, fontWeight = FontWeight.Bold, fontSize = 24.sp, lineHeight = 32.sp, letterSpacing = (-0.02).em, color = Ink.text)
    val section = TextStyle(fontFamily = Faces.unbounded, fontWeight = FontWeight.Bold, fontSize = 15.sp, lineHeight = 20.sp, color = Ink.text)
    val body = TextStyle(fontFamily = Faces.grotesk, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 24.sp, color = Ink.text)
    val small = TextStyle(fontFamily = Faces.grotesk, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 20.sp, color = Ink.textMuted)
    val label = TextStyle(fontFamily = Faces.grotesk, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp, color = Ink.text)
    /** The "cota": mono, 12px, uppercase, 0.08em tracking, like a topo map annotation. */
    val cota = TextStyle(fontFamily = Faces.mono, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = 0.08.em, color = Ink.textMuted)
    val mono = TextStyle(fontFamily = Faces.mono, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp, color = Ink.textMuted)
    val monogram = TextStyle(fontFamily = Faces.unbounded, fontWeight = FontWeight.Bold, fontSize = 18.sp, lineHeight = 22.sp)
}
