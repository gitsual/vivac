package dev.vivac.launcher.petate

import java.math.BigDecimal
import java.math.MathContext
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.roundToLong

/**
 * The search field as a calculator: sums ("2+3*4", "10% de 150") and unit conversions ("5 km en mi").
 * Anything else, including a bare number, is not a calculation and gives null.
 */
object Calc {
    fun answer(query: String): String? {
        val q = query.trim().lowercase(Locale.ROOT)
        if (q.isEmpty()) return null
        return convert(q) ?: percent(q)?.let(::format) ?: sum(q)?.let(::format)
    }

    // ---- Sums ----

    private fun sum(q: String): Double? {
        val parser = Parser(q)
        val value = parser.parse() ?: return null
        // A bare number is something you are searching for, not a sum.
        return value.takeIf { parser.operators > 0 && it.isFinite() }
    }

    private val PERCENT = Regex("""^(.+?)\s*%\s+(?:de|of)\s+(.+)$""")

    private fun percent(q: String): Double? {
        val (p, of) = PERCENT.find(q)?.destructured ?: return null
        val a = Parser(p).parse() ?: return null
        val b = Parser(of).parse() ?: return null
        return (a / 100 * b).takeIf { it.isFinite() }
    }

    /** Recursive descent over + - × ÷ ^ and brackets; a decimal comma or point. */
    private class Parser(text: String) {
        private val s = text.replace('×', '*').replace('÷', '/').replace(" ", "")
        private var i = 0
        var operators = 0; private set

        fun parse(): Double? = runCatching { expr().takeIf { i == s.length } }.getOrNull()

        private fun expr(): Double {
            var v = term()
            while (i < s.length && (s[i] == '+' || s[i] == '-')) {
                val op = s[i++]; operators++
                v = if (op == '+') v + term() else v - term()
            }
            return v
        }

        private fun term(): Double {
            var v = power()
            while (i < s.length && (s[i] == '*' || s[i] == '/')) {
                val op = s[i++]; operators++
                val r = power()
                if (op == '/' && r == 0.0) error("division by zero")
                v = if (op == '*') v * r else v / r
            }
            return v
        }

        private fun power(): Double {
            val base = unary()
            if (i < s.length && s[i] == '^') { i++; operators++; return base.pow(power()) }
            return base
        }

        private fun unary(): Double {
            if (i < s.length && s[i] == '-') { i++; return -unary() }
            if (i < s.length && s[i] == '(') {
                i++
                val v = expr()
                check(i < s.length && s[i] == ')')
                i++
                return v
            }
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] == ',' || s[i] == '.')) i++
            return s.substring(start, i).replace(',', '.').toDouble()
        }
    }

    // ---- Units ----

    private class Unit(val kind: String, val shown: String, val factor: Double)

    private val UNITS: Map<String, Unit> = buildMap {
        fun add(kind: String, shown: String, factor: Double, vararg names: String) {
            val u = Unit(kind, shown, factor)
            (names.toList() + shown.lowercase(Locale.ROOT)).forEach { put(it, u) }
        }
        add("length", "m", 1.0, "metro", "metros", "meter", "meters")
        add("length", "km", 1000.0, "kilometro", "kilómetro", "kilometros", "kilómetros", "kilometer", "kilometers")
        add("length", "cm", 0.01, "centimetro", "centímetro", "centimetros", "centímetros")
        add("length", "mm", 0.001, "milimetro", "milímetro", "milimetros", "milímetros")
        add("length", "mi", 1609.344, "milla", "millas", "mile", "miles")
        add("length", "ft", 0.3048, "pie", "pies", "foot", "feet")
        add("length", "in", 0.0254, "pulgada", "pulgadas", "inch", "inches")
        add("length", "yd", 0.9144, "yarda", "yardas", "yard", "yards")
        add("mass", "kg", 1.0, "kilo", "kilos", "kilogramo", "kilogramos")
        add("mass", "g", 0.001, "gramo", "gramos", "gram", "grams")
        add("mass", "mg", 1e-6, "miligramo", "miligramos")
        add("mass", "t", 1000.0, "tonelada", "toneladas", "tonne", "tonnes")
        add("mass", "lb", 0.45359237, "libra", "libras", "pound", "pounds", "lbs")
        add("mass", "oz", 0.028349523125, "onza", "onzas", "ounce", "ounces")
        add("volume", "l", 1.0, "litro", "litros", "liter", "liters", "litre", "litres")
        add("volume", "ml", 0.001, "mililitro", "mililitros")
        add("volume", "cl", 0.01, "centilitro", "centilitros")
        add("volume", "gal", 3.785411784, "galon", "galón", "galones", "gallon", "gallons")
        add("time", "s", 1.0, "seg", "segundo", "segundos", "sec", "second", "seconds")
        add("time", "min", 60.0, "minuto", "minutos", "minute", "minutes")
        add("time", "h", 3600.0, "hora", "horas", "hour", "hours")
        add("time", "días", 86400.0, "dia", "día", "dias", "day", "days", "d")
        add("time", "semanas", 604800.0, "semana", "week", "weeks")
        add("speed", "m/s", 1.0)
        add("speed", "km/h", 1 / 3.6, "kmh", "kph")
        add("speed", "mph", 0.44704)
        add("speed", "nudos", 0.514444, "nudo", "kn", "knots")
        add("data", "bytes", 1.0, "byte")
        add("data", "KB", 1024.0)
        add("data", "MB", 1024.0.pow(2))
        add("data", "GB", 1024.0.pow(3))
        add("data", "TB", 1024.0.pow(4))
        add("temperature", "°C", 0.0, "c", "celsius", "centigrados", "centígrados")
        add("temperature", "°F", 0.0, "f", "fahrenheit")
        add("temperature", "K", 0.0, "kelvin")
    }

    private val CONVERSION = Regex("""^(-?\d+(?:[.,]\d+)?)\s*(.+?)\s+(?:en|a|to|in)\s+(.+)$""")

    private fun convert(q: String): String? {
        val (n, fromName, toName) = CONVERSION.find(q)?.destructured ?: return null
        val from = UNITS[fromName.trim()] ?: return null
        val to = UNITS[toName.trim()] ?: return null
        if (from.kind != to.kind) return null
        val value = n.replace(',', '.').toDouble()
        val result = if (from.kind == "temperature") temperature(value, from.shown, to.shown) else value * from.factor / to.factor
        return "${format(result)} ${to.shown}"
    }

    private fun temperature(v: Double, from: String, to: String): Double {
        val celsius = when (from) { "°F" -> (v - 32) * 5 / 9; "K" -> v - 273.15; else -> v }
        return when (to) { "°F" -> celsius * 9 / 5 + 32; "K" -> celsius + 273.15; else -> celsius }
    }

    // ---- Showing it ----

    /**
     * Spanish style: "2,5", "1024", "1.000.000" (four-digit numbers are not grouped); whole numbers stay whole,
     * the rest keep six significant digits.
     */
    private fun format(v: Double): String {
        val symbols = DecimalFormatSymbols(Locale.forLanguageTag("es-ES")).apply { groupingSeparator = '.'; decimalSeparator = ',' }
        val f = DecimalFormat("#,##0.##########", symbols).apply { isGroupingUsed = abs(v) >= 10_000 }
        if (abs(v - v.roundToLong()) < 1e-9 && abs(v) < 1e15) return f.format(v.roundToLong())
        return f.format(BigDecimal(v).round(MathContext(6)).stripTrailingZeros())
    }
}
