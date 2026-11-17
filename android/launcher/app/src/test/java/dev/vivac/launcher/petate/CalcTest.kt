package dev.vivac.launcher.petate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CalcTest {
    @Test
    fun `arithmetic follows the usual precedence, with brackets, powers and percentages`() {
        assertEquals("14", Calc.answer("2+3*4"))
        assertEquals("20", Calc.answer("(2+3)*4"))
        assertEquals("1024", Calc.answer("2^10"))
        assertEquals("-3", Calc.answer("-5 + 2"))
        assertEquals("2,5", Calc.answer("5/2"))
        assertEquals("15", Calc.answer("10% de 150"))
        assertEquals("15", Calc.answer("10% of 150"))
        assertEquals("3,75", Calc.answer("1,5 × 2,5"))
        assertEquals("4", Calc.answer("8 ÷ 2"))
        assertEquals("0,333333", Calc.answer("1/3"))
        assertEquals("1.000.000", Calc.answer("1000*1000"))
    }

    @Test
    fun `plain numbers, names and broken sums are not calculations`() {
        assertNull(Calc.answer("42"))
        assertNull(Calc.answer("signal"))
        assertNull(Calc.answer("2+"))
        assertNull(Calc.answer("(2+3"))
        assertNull(Calc.answer("1/0"))
        assertNull(Calc.answer(""))
        assertNull(Calc.answer("2 3"))
        assertNull(Calc.answer("10% de"))
    }

    @Test
    fun `units convert within their kind, in spanish or english`() {
        assertEquals("3,10686 mi", Calc.answer("5 km en mi"))
        assertEquals("3,10686 mi", Calc.answer("5km to miles"))
        assertEquals("100 °C", Calc.answer("212 f a c"))
        assertEquals("32 °F", Calc.answer("0 °c en °f"))
        assertEquals("1,5 kg", Calc.answer("1500 g en kg"))
        assertEquals("2,20462 lb", Calc.answer("1 kg en lb"))
        assertEquals("250 ml", Calc.answer("0,25 l en ml"))
        assertEquals("100 km/h", Calc.answer("27,7778 m/s en km/h"))
        assertEquals("1 GB", Calc.answer("1024 mb en gb"))
        assertEquals("90 min", Calc.answer("1,5 h en min"))
        assertNull(Calc.answer("5 km en kg"))
        assertNull(Calc.answer("5 parsecs en km"))
    }
}
