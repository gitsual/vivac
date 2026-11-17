package dev.vivac.launcher.apps

/**
 * vivac's own icon for each app: one-ink line glyphs on a 24-unit grid, 1.75 stroke, round caps and joins,
 * drawn in the tile's tone. Every tile looks like it came from the same hand; an app without one here gets
 * its monogram. Approved set: the "vivac · glifos de apps" canvas (17-11-2026).
 */
object Glyphs {
    val all: Map<String, String> = mapOf(
        "app.alextran.immich" to "M12 12c0-4 2-7 5-7s2 5-5 7 M12 12c4 0 7 2 7 5s-5 2-7-5 M12 12c0 4-2 7-5 7s-2-5 5-7 M12 12c-4 0-7-2-7-5s5-2 7 5", // Immich
        "app.attestation.auditor" to "M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z M8.5 12l2.5 2.5 4.5-5", // Auditor
        "app.grapheneos.apps" to "M4 8l8-4 8 4v9l-8 4-8-4z M12 9v7 M9 13l3 3 3-3", // Apps
        "app.grapheneos.camera" to "M3 8h4l2-3h6l2 3h4v11H3z M8.5 13a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0 -7 0", // Cámara
        "app.grapheneos.info" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M12 11v6 M12 7.5h.01", // Info
        "app.grapheneos.pdfviewer" to "M6 3h8l5 5v13H6z M14 3v5h5 M9 13h6 M9 16.5h4", // Visor de PDF
        "app.organicmaps" to "M3 6l5-2 8 3 5-2v13l-5 2-8-3-5 2z M8 4v13 M16 7v13", // Organic Maps
        "app.vanadium.browser" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M15.5 8.5l-2 5-5 2 2-5z", // Vanadium
        "ch.deletescape.lawnchair" to "M7 4h10v8H7z M5 12h14 M7 12l-1 8 M17 12l1 8 M7 16h10", // Lawnchair
        "com.android.calculator2" to "M5 3h14v18H5z M8 7h8 M8.5 11.5h.01 M12 11.5h.01 M15.5 11.5h.01 M8.5 15h.01 M12 15h.01 M15.5 15h.01 M8.5 18h.01 M12 18h.01 M15.5 18h.01", // Calculadora
        "com.android.chrome" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M8.5 12a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0 -7 0 M12 8.5h8.2 M9 13.8L4.9 6.6 M15 13.8L11 21", // Chrome
        "com.android.contacts" to "M8.5 8a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0 -7 0 M5 20a7 7 0 0 1 14 0", // Contactos
        "com.android.deskclock" to "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0 M12 7v5l3.5 2", // Reloj
        "com.android.dialer" to "M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z", // Teléfono
        "com.android.documentsui" to "M3 6h6l2 2h10v11H3z", // Archivos
        "com.android.gallery3d" to "M3 5h18v14H3z M3 16l5-5 4 4 3-3 6 6 M14.5 9a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0", // Galería
        "com.android.messaging" to "M4 5h16v11H9l-5 4z M8 9h8 M8 12h5", // Mensajes
        "com.android.settings" to "M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0 M5.5 12a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0 -13 0 M12 2.5v3 M12 18.5v3 M2.5 12h3 M18.5 12h3 M5.3 5.3l2.1 2.1 M16.6 16.6l2.1 2.1 M5.3 18.7l2.1-2.1 M16.6 7.4l2.1-2.1", // Ajustes
        "com.android.vending" to "M6 4l13 8-13 8z M6 4l8 8-8 8", // Play Store
        "com.anthropic.claude" to "M12 3v18 M3 12h18 M5.6 5.6l12.8 12.8 M18.4 5.6L5.6 18.4", // Claude
        "com.azure.authenticator" to "M6 11h12v9H6z M8.5 11V8a3.5 3.5 0 0 1 7 0v3 M12 14.5V17", // Authenticator
        "com.caixabankpc.nowpay" to "M3 6h18v12H3z M3 10h18 M6.5 14.5h4", // CaixaBank
        "com.correos.prepago" to "M2 7h12v9H2z M14 10h4l3 3v3h-7z M4.2 18a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0 M15.2 18a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0", // Correos
        "com.divisait.quironsalud" to "M9 3h6v6h6v6h-6v6H9v-6H3V9h6z", // Quirónsalud
        "com.google.android.GoogleCamera" to "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0 M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M12 3.5V8 M20.5 12H16 M12 20.5V16 M3.5 12H8", // Cámara Pixel
        "com.google.android.apps.authenticator2" to "M3 7h18v10H3z M7 12h.01 M10.5 12h.01 M14 12h.01 M17.5 12h.01", // Authenticator G
        "com.google.android.apps.docs" to "M9 4h6l6 10-3 6H6l-3-6z M3 14h18 M9 4l6 10", // Drive
        "com.google.android.apps.maps" to "M12 21s-6-5.5-6-11a6 6 0 0 1 12 0c0 5.5-6 11-6 11z M9.8 10a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0 -4.4 0", // Maps
        "com.google.android.apps.walletnfcrel" to "M3 7h16a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H3z M3 7V6a2 2 0 0 1 2-2h11v3 M16.5 13.5h.01", // Wallet
        "com.google.android.gm" to "M4 6h16v12H4z M4 6l8 6.5L20 6", // Gmail
        "com.google.android.googlequicksearchbox" to "M4 10.5a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0 -13 0 M15.2 15.2L20 20 M18.5 3v4 M16.5 5h4", // Google
        "com.google.android.youtube" to "M3 7.5C3 6 4 5 5.5 5h13C20 5 21 6 21 7.5v9c0 1.5-1 2.5-2.5 2.5h-13C4 19 3 18 3 16.5z M10 9l5 3-5 3z", // YouTube
        "com.google.ar.lens" to "M4 9V6a2 2 0 0 1 2-2h3 M15 4h3a2 2 0 0 1 2 2v3 M20 15v3a2 2 0 0 1-2 2h-3 M9 20H6a2 2 0 0 1-2-2v-3 M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0", // Lens
        "com.instagram.android" to "M8 3h8a5 5 0 0 1 5 5v8a5 5 0 0 1-5 5H8a5 5 0 0 1-5-5V8a5 5 0 0 1 5-5z M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M17.5 6.5h.01", // Instagram
        "com.instagram.barcelona" to "M15.5 12a3.5 3.5 0 1 1-1-2.5 M15.5 9v4.5a2.5 2.5 0 0 0 5 0V12a8.5 8.5 0 1 0-3.5 6.9", // Threads
        "com.intsig.camscanner" to "M4 8V4h4 M16 4h4v4 M20 16v4h-4 M8 20H4v-4 M7 12h10", // CamScanner
        "com.linkedin.android" to "M3 8h18v11H3z M8.5 8V5h7v3 M3 13h18", // LinkedIn
        "com.mi.AthleanX" to "M6 7v10 M3 9v6 M18 7v10 M21 9v6 M6 12h12", // 6 Pack
        "com.microsoft.office.outlook" to "M3 10l9-6 9 6v10H3z M3 10l9 6 9-6", // Outlook
        "com.microsoft.teams" to "M6 8a3 3 0 1 0 6 0a3 3 0 1 0 -6 0 M3.5 20a5.5 5.5 0 0 1 11 0 M14.7 9a2.3 2.3 0 1 0 4.6 0a2.3 2.3 0 1 0 -4.6 0 M15.5 14.2A4.5 4.5 0 0 1 21 18.5", // Teams
        "com.module.notelycompose.android" to "M9 5a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0z M5.5 11a6.5 6.5 0 0 0 13 0 M12 17.5V21", // Notely
        "com.openai.chatgpt" to "M12 3l7.8 4.5v9L12 21l-7.8-4.5v-9z M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0", // ChatGPT
        "com.prosegur.alarmas" to "M6 18v-6a6 6 0 0 1 12 0v6 M4 18h16v2H4z M12 3v1.5 M4.5 6l1 1 M19.5 6l-1 1", // Alarmas
        "com.qaracter.asybapp" to "M12 20s-8-4.8-8-10.5A4.5 4.5 0 0 1 12 7a4.5 4.5 0 0 1 8 2.5C20 15.2 12 20 12 20z M12 10v5 M9.5 12.5h5", // Adeslas
        "com.rcf.renaul1and" to "M3 8h18v11H3z M5.2 13.5a2.8 2.8 0 1 0 5.6 0a2.8 2.8 0 1 0 -5.6 0 M14 12h4 M14 15h4 M7 8l9-4", // Radio Code
        "com.samsung.android.oneconnect" to "M9.5 12a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0 -5 0 M3.2 5a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0 M17.2 5a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0 M3.2 19a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0 M17.2 19a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0 M6.3 6.3l3.9 3.9 M17.7 6.3l-3.9 3.9 M6.3 17.7l3.9-3.9 M17.7 17.7l-3.9-3.9", // SmartThings
        "com.shazam.android" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M8 11v2 M11 8.5v7 M14 7v10 M17 10.5v3", // Shazam
        "com.sportmaniac_live_app_android.evedeport" to "M8 4h8v6a4 4 0 0 1-8 0z M8 6H5a3 3 0 0 0 3 4 M16 6h3a3 3 0 0 1-3 4 M12 14v3 M8.5 20h7 M10 17h4", // Evedeport
        "com.spotify.music" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M7 9.5c3.5-1 7-.6 10 1 M7.8 12.8c2.8-.7 5.6-.4 8 .9 M8.6 15.8c2.1-.5 4.2-.3 6 .7", // Spotify
        "com.stremio.one" to "M12 3l9 9-9 9-9-9z M10.5 9.5l4 2.5-4 2.5z", // Stremio
        "com.tailscale.ipn" to "M4.4 6a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M10.4 6a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M16.4 6a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M4.4 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M10.4 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M16.4 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M4.4 18a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M10.4 18a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0 M16.4 18a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0", // Tailscale
        "com.termux" to "M5 7l5 5-5 5 M12 18h7", // Termux
        "com.termux.api" to "M3 8l4 4-4 4 M9 17h3 M16 4v3 M20 4v3 M15 7h6v3a3 3 0 0 1-6 0z M18 13v6", // Termux:API
        "com.termux.boot" to "M3 8l4 4-4 4 M9 17h3 M18 5v5 M15 7a5 5 0 1 0 6 0", // Termux:Boot
        "com.tplink.tpm5" to "M2.5 9a14 14 0 0 1 19 0 M5.5 12.5a9.5 9.5 0 0 1 13 0 M8.5 16a5 5 0 0 1 7 0 M12 19.5h.01", // Deco
        "com.tribab.tricount.android" to "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0 M12 3.5V12l7.4 4.2 M12 12l-7.4 4.2", // tricount
        "com.twitter.android" to "M5 4l14 16 M19 4L5 20", // X
        "com.ubercab" to "M4 15l1.5-5a2 2 0 0 1 1.9-1.5h9.2a2 2 0 0 1 1.9 1.5L20 15v3H4z M4 15h16 M6.5 18v2 M17.5 18v2", // Uber
        "com.ubercab.eats" to "M4 11a8 6 0 0 1 16 0z M3.5 14.5h17 M5 18h14a1 1 0 0 1-1 2H6a1 1 0 0 1-1-2z", // Uber Eats
        "com.valvesoftware.android.steam.community" to "M7 8h10a4 4 0 0 1 4 4l.5 4a2.5 2.5 0 0 1-4.3 1.8L15 15H9l-2.2 2.8A2.5 2.5 0 0 1 2.5 16L3 12a4 4 0 0 1 4-4z M7 11v3 M5.5 12.5h3 M15.5 12h.01 M17.5 13.5h.01", // Steam
        "com.whatsapp" to "M12 3.5a8.5 8.5 0 1 1-4.3 15.8L3.5 20.5l1.2-4.1A8.5 8.5 0 0 1 12 3.5z M9 9.5c.4 2.4 2.6 4.9 5.5 5.5", // WhatsApp
        "com.zhiliaoapp.musically" to "M14 3v11.5a3.5 3.5 0 1 1-3.5-3.5 M14 3c.5 2.5 2.5 4.5 5 4.5", // TikTok
        "de.nulide.findmydevice" to "M6 12a6 6 0 1 0 12 0a6 6 0 1 0 -12 0 M10.5 12a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0 -3 0 M12 3v4 M12 17v4 M3 12h4 M17 12h4", // FMD
        "de.traderepublic.app" to "M3 20h18 M5 16l4-5 4 3 6-8 M15 6h4v4", // Trade Republic
        "dev.lorty.cocina" to "M4 10h16 M5 10v6a4 4 0 0 0 4 4h6a4 4 0 0 0 4-4v-6 M2 10h2 M20 10h2 M9 7c0-1 1-1 1-2.5 M14 7c0-1 1-1 1-2.5", // Cocina
        "dev.lorty.locapp" to "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0 M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M12 12l5.5-5.5", // LocApp
        "es.aeat.pin24h" to "M4 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M12 12h9 M17 12v3 M20 12v2", // Cl@ve PIN
        "es.gob.carpeta" to "M3 6h6l2 2h10v11H3z M8 14h8", // Carpeta ciudadana
        "es.gob.interior.policia.midni" to "M3 6h18v12H3z M6.5 11a2 2 0 1 0 4 0a2 2 0 1 0 -4 0 M5.5 15.5a3 3 0 0 1 6 0 M14 10h4 M14 13h4", // MiDNI
        "es.unicajabanco.app" to "M3 10l9-6 9 6 M5 10v8 M9.5 10v8 M14.5 10v8 M19 10v8 M3 20h18", // Unicaja
        "io.heckel.ntfy" to "M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z M10 20.5a2 2 0 0 0 4 0", // ntfy
        "me.kavishdevar.librepods" to "M7 4a3 3 0 0 1 3 3v3a3 3 0 0 1-3 3z M7 13v7 M17 4a3 3 0 0 0-3 3v3a3 3 0 0 0 3 3z M17 13v7", // LibrePods
        "net.inverline.bancosabadell.officelocator.android" to "M12 21s-6-5.5-6-11a6 6 0 0 1 12 0c0 5.5-6 11-6 11z M9 12.5V9.5l3-2 3 2v3", // Banco Sabadell
        "org.moire.ultrasonic" to "M4 15v-3a8 8 0 0 1 16 0v3 M4 14h3v6H4z M17 14h3v6h-3z", // Ultrasonic
        "org.oxycblt.auxio" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M9.5 12a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0 -5 0 M12 6a6 6 0 0 1 6 6", // Auxio
        "org.stypox.dicio" to "M4 10v4 M8 7v10 M12 4v16 M16 7v10 M20 10v4", // Dicio
        "org.telegram.messenger" to "M21 4L3 11l6 2.5L11 20l3-4.5 5 3.5z M9 13.5L21 4", // Telegram
        "pdb.app" to "M12 3l2.2 4.6 5 .7-3.6 3.5.9 5-4.5-2.4-4.5 2.4.9-5L4.8 8.3l5-.7z", // Pdb
        "spam.blocker" to "M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z M8.5 8.5l7 7", // Bloqueador de spam
    )

    fun of(packageName: String): String? = all[packageName]
}
