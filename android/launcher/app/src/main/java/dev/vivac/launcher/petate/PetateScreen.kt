package dev.vivac.launcher.petate

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.em
import dev.vivac.launcher.theme.Brand
import dev.vivac.launcher.theme.Contours
import kotlinx.coroutines.launch
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.runtime.produceState
import dev.vivac.launcher.core.CalendarEvent
import dev.vivac.launcher.core.Contact
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.vivac.launcher.apps.AppFace
import dev.vivac.launcher.apps.LocalCounts
import dev.vivac.launcher.apps.LocalDots
import dev.vivac.launcher.apps.InstalledApp
import dev.vivac.launcher.apps.Profile
import dev.vivac.launcher.theme.AppTile
import androidx.compose.ui.graphics.Color
import dev.vivac.launcher.core.Zone
import dev.vivac.launcher.campamento.carriable
import dev.vivac.launcher.campamento.Spot
import dev.vivac.launcher.campamento.Held
import dev.vivac.launcher.campamento.DragBoard
import dev.vivac.launcher.theme.Glyph
import dev.vivac.launcher.theme.Ink
import dev.vivac.launcher.theme.LineIcon
import dev.vivac.launcher.theme.Monogram
import dev.vivac.launcher.theme.Type

@Composable
fun PetateScreen(
    apps: List<InstalledApp>,
    hidden: Set<String>,
    focusSearch: Boolean,
    onOpenApp: (String) -> Unit,
    onAppMenu: (String) -> Unit,
    drag: DragBoard? = null,
    onDrop: (Held, Spot) -> Unit = { _, _ -> },
    onLand: () -> Unit = {},
    modifier: Modifier = Modifier,
    onCopy: (String) -> Unit = {},
    onWebSearch: (String) -> Unit = {},
    onStoreSearch: (String) -> Unit = {},
    shortcuts: List<FoundShortcut> = emptyList(),
    onOpenShortcut: (FoundShortcut) -> Unit = {},
    columns: Int = 4,
    profiles: List<Profile> = emptyList(),
    onOpenInProfile: (String, Long) -> Unit = { _, _ -> },
    onLockProfile: (Profile) -> Unit = {},
    findContacts: (String) -> List<Contact> = { emptyList() },
    findEvents: (String) -> List<CalendarEvent> = { emptyList() },
    onOpenContact: (Contact) -> Unit = {},
    onOpenEvent: (CalendarEvent) -> Unit = {},
    findFiles: (String) -> List<dev.vivac.launcher.core.FoundFile> = { emptyList() },
    onOpenFile: (dev.vivac.launcher.core.FoundFile) -> Unit = {},
    onOpenSettingsPage: (dev.vivac.launcher.core.SystemPage) -> Unit = {},
    /** Opening the hidden apps runs through this, which may first ask for your fingerprint or PIN. */
    askToSeeHidden: (() -> Unit) -> Unit = { it() },
    /** Where contacts and events are looked up: off the main thread. */
    io: kotlinx.coroutines.CoroutineDispatcher = kotlinx.coroutines.Dispatchers.IO,
    /** Past searches that opened something, newest first; a tap searches again. */
    searches: List<String> = emptyList(),
    onSearched: (String) -> Unit = {},
    onClearSearches: () -> Unit = {},
    /** What Android's status bar would say, which hides while the petate is up: the hour, the connections, the battery. */
    hour: String = "",
    status: dev.vivac.launcher.campamento.PhoneStatus = dev.vivac.launcher.campamento.PhoneStatus(),
    battery: Int = 0,
    charging: Boolean = false,
) {
    var query by rememberSaveable { mutableStateOf("") }
    // Whatever a search opens, the search is remembered.
    fun <T> searched(open: (T) -> Unit): (T) -> Unit = { x -> if (query.isNotBlank()) onSearched(query.trim()); open(x) }
    val openApp = searched(onOpenApp)
    val openShortcut = searched(onOpenShortcut)
    val openContact = searched(onOpenContact)
    val openEvent = searched(onOpenEvent)
    val openFile = searched(onOpenFile)
    val openPage = searched(onOpenSettingsPage)
    val webSearch = searched(onWebSearch)
    val storeSearch = searched(onStoreSearch)
    // Holding an app and moving lifts it out of the petate, to be carried onto the camp.
    val carry: @Composable (InstalledApp, Color) -> Modifier? = { app, tone ->
        drag?.let { Modifier.carriable(it, Held(app, Zone.Petate, tone), app.label, { openApp(app.packageName) }, { onAppMenu(app.packageName) }, onDrop, onLand) }
    }
    var showHidden by rememberSaveable { mutableStateOf(false) }
    if (hidden.isEmpty()) showHidden = false
    // A chosen profile (work, private space) shows only its apps.
    var profileId by rememberSaveable { mutableStateOf<Long?>(null) }
    val profile = profiles.firstOrNull { it.id == profileId }
    val found = remember(apps, hidden, showHidden, query, profile) {
        Pack.search(profile?.apps ?: Pack.visible(apps, hidden, showHidden), query)
    }
    // One run, A to Z: no shelves.
    val run = remember(found) { Pack.sorted(found) }
    val jumps = remember(run) { Pack.jumps(run) }
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var letter by remember { mutableStateOf<Char?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(focusSearch) { if (focusSearch) focus.requestFocus() }

    var searching by remember { mutableStateOf(false) }
    BoxWithConstraints(modifier.fillMaxSize().background(Ink.deep)) {
        // On its side the phone is short: the search, the pulls and the label share one thin bar, and the apps
        // get the whole width and the rest of the height under it. Upright, everything is stacked as ever.
        val wide = maxWidth > maxHeight
        // On its side a tile stays about as wide as it is upright, so a row holds more of them.
        val cell = maxHeight / columns * 0.8f
        Contours(Modifier.fillMaxSize(), color = Ink.surface)
        // On its side the cloth runs down to the screen's edge, under the navigation bar; only the keyboard lifts it.
        val safe = if (wide) {
            Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).windowInsetsPadding(WindowInsets.ime)
        } else Modifier.windowInsetsPadding(WindowInsets.safeDrawing)
        val navBar = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        BoxWithConstraints(Modifier.fillMaxSize().then(safe)) {
        // On its side with the keyboard up there is room for the bar and one row: smaller tiles, no zip, no altimeter.
        val cramped = wide && maxHeight < 200.dp
        Column(Modifier.fillMaxSize().padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = if (wide) 0.dp else 12.dp)) {
        // Over the bag, in place of Android's bar: the hour, the connections, the battery. With the keyboard up
        // on its side there is no room for it.
        if (!cramped) dev.vivac.launcher.campamento.StatusStrip(hour, status, battery, charging, Modifier.padding(horizontal = 14.dp), compact = wide)
        // The drawcord closes the bag's mouth; inside, the search, the label, the zip pulls. On its side the
        // cord and the hem give their height to a third row of apps.
        if (!wide) BagCord(Modifier.padding(horizontal = 18.dp))
        Column(Modifier.weight(1f).fillMaxWidth().bagCloth(if (wide) BagMouth else BagShape)) {
        if (!wide) BagHem()
        val field: @Composable () -> Unit = {
            SearchField(query, { query = it }, focus, { searching = it }, when { cramped -> 40.dp; wide -> 44.dp; else -> 50.dp }) { run.singleOrNull()?.let { openApp(it.packageName) } }
        }
        val past: @Composable () -> Unit = {
            if (searches.isNotEmpty() && searching && query.isBlank() && !showHidden && profile == null) {
                Text("BÚSQUEDAS", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.semantics { heading() })
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    searches.forEach { q -> Chip(q, false) { query = q } }
                    Chip("Borrar", false, onClearSearches)
                }
            }
        }
        // The zip pulls open what is kept apart: the hidden apps and the other profiles. Nothing kept apart, no pulls.
        val pulled = hidden.isNotEmpty() || profiles.isNotEmpty()
        val pulls: @Composable () -> Unit = {
            if (hidden.isNotEmpty()) PullTab("Ocultas · ${hidden.size}", profile == null && showHidden) {
                if (showHidden) showHidden = false else askToSeeHidden { showHidden = true; profileId = null }
            }
            profiles.forEach { p -> PullTab(p.kind.title, profileId == p.id) { profileId = if (profileId == p.id) null else p.id; showHidden = false } }
        }
        // What the search finds besides apps: a sum, people, files, events, settings pages, shortcuts.
        val answers: @Composable () -> Unit = {
            val answer = remember(query) { Calc.answer(query) }
            if (answer != null) Answer(answer) { onCopy(answer) }
            val people by produceState(emptyList<Contact>(), query) { value = kotlinx.coroutines.withContext(io) { findContacts(query) } }
            val agenda by produceState(emptyList<CalendarEvent>(), query) { value = kotlinx.coroutines.withContext(io) { findEvents(query) } }
            if (people.isNotEmpty()) Results("CONTACTOS", people.map { it.name to null }) { openContact(people[it]) }
            val found by produceState(emptyList<dev.vivac.launcher.core.FoundFile>(), query) { value = kotlinx.coroutines.withContext(io) { findFiles(query) } }
            if (found.isNotEmpty()) Results("ARCHIVOS", found.map { it.name to it.kind.title }) { openFile(found[it]) }
            if (agenda.isNotEmpty()) Results("CALENDARIO", agenda.map { it.title to When.of(it.startMillis) }) { openEvent(agenda[it]) }
            val pages = remember(query) { Pack.searchSettings(query) }
            if (pages.isNotEmpty()) Results("AJUSTES DE ANDROID", pages.map { it.title to it.detail }) { openPage(pages[it]) }
            val foundShortcuts = remember(query, shortcuts) { Pack.searchShortcuts(shortcuts, query).take(4) }
            if (foundShortcuts.isNotEmpty()) ShortcutResults(foundShortcuts, openShortcut)
            if (query.isNotBlank()) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("Buscar en la web", false) { webSearch(query.trim()) }
                    Chip("Buscar en la tienda", false) { storeSearch(query.trim()) }
                }
            }
            if (run.isEmpty() && answer == null && pages.isEmpty() && foundShortcuts.isEmpty() && people.isEmpty() && agenda.isEmpty() && found.isEmpty()) {
                Text("Nada en el petate con «$query».", style = Type.body.copy(color = Ink.textMuted))
            }
        }
        // On its side an open profile's bar and the past searches ride on top of the apps, as their first row.
        val lead = if (wide && (profile != null || (searches.isNotEmpty() && searching && query.isBlank() && !showHidden))) 1 else 0
        val pockets: @Composable (Modifier) -> Unit = { into ->
            Column(into) {
                if (!cramped) Zipper()
                LazyVerticalGrid(
                    columns = if (wide) GridCells.Adaptive(cell) else GridCells.Fixed(columns),
                    state = grid,
                    modifier = Modifier.weight(1f).padding(end = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(if (wide) 12.dp else 14.dp),
                    // Air between the zip and the first row; on its side the last row clears the navigation bar.
                    contentPadding = PaddingValues(top = if (cramped) 0.dp else 12.dp, bottom = if (wide) 24.dp + navBar else 24.dp),
                ) {
                    if (lead == 1) item(key = "lead", span = { GridItemSpan(maxLineSpan) }) {
                        Column(Modifier.padding(end = 6.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            if (profile != null) ProfileBar(profile) { onLockProfile(profile) }
                            past()
                        }
                    }
                    items(run, key = { it.packageName }) { app ->
                        val deep = app.packageName.startsWith("com.termux")
                        val tone = if (app.packageName == "com.termux") Ink.ok else Ink.tileTones[Pack.toneIndex(app, Ink.tileTones.size)]
                        AppTile(
                            label = app.label,
                            background = if (deep) Ink.deep else Ink.surface,
                            border = Ink.field,
                            tile = if (cramped) 48.dp else 56.dp,
                            onClick = { if (profile != null) onOpenInProfile(app.packageName, profile.id) else openApp(app.packageName) },
                            onLongClick = { if (profile == null) onAppMenu(app.packageName) },
                            dot = profile == null && app.packageName in LocalDots.current,
                            count = if (profile == null) LocalCounts.current[app.packageName] ?: 0 else 0,
                            badge = profile?.let { if (it.kind == Profile.Kind.WORK) "TRAB" else "PRIV" },
                            gestures = if (profile == null) carry(app, tone) else null,
                        ) {
                            AppFace(app, tone)
                        }
                    }
                    // On its side, what the search finds besides apps comes after them, in the same run.
                    if (wide && query.isNotBlank()) item(key = "answers", span = { GridItemSpan(maxLineSpan) }) {
                        Column(Modifier.padding(end = 6.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { answers() }
                    }
                }
            }
        }
        val altimeter: @Composable () -> Unit = {
            Altimeter(jumps.keys, letter, tight = wide) { ch ->
                letter = ch
                jumps[ch]?.let { scope.launch { grid.scrollToItem(it + lead) } }
            }
        }
        if (wide) {
            Column(
                Modifier.weight(1f).padding(start = 14.dp, top = if (cramped) 4.dp else 8.dp),
                verticalArrangement = Arrangement.spacedBy(if (cramped) 4.dp else 8.dp),
            ) {
                // The search takes all the bar the pulls and the label leave it.
                Row(
                    Modifier.fillMaxWidth().padding(end = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(Modifier.weight(1f)) { field() }
                    if (pulled && !cramped) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { pulls() }
                    if (!cramped) BagTag()
                }
                Row(Modifier.weight(1f)) {
                    pockets(Modifier.weight(1f))
                    // The strap stops above the navigation bar, so its last letters are not under the home gesture.
                    if (!cramped) Box(Modifier.padding(bottom = navBar)) { altimeter() }
                }
            }
        } else {
            Column(
                Modifier.weight(1f).padding(start = 14.dp, top = 14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.padding(end = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    field()
                    BagLabel()
                    if (profile != null) ProfileBar(profile) { onLockProfile(profile) }
                    past()
                    if (pulled) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) { pulls() }
                    answers()
                }
                Row(Modifier.weight(1f)) {
                    pockets(Modifier.weight(1f))
                    altimeter()
                }
            }
        }
        }
        }
        }
    }
}

/** A profile's state, and the button that pauses or locks it (and back). */
@Composable
private fun ProfileBar(profile: Profile, onToggle: () -> Unit) {
    val private = profile.kind == Profile.Kind.PRIVATE
    val state = when {
        private && profile.locked -> "Espacio privado bloqueado: desbloquéalo para ver sus apps."
        private -> "Espacio privado abierto · ${profile.apps.size} apps"
        profile.locked -> "Perfil de trabajo en pausa: sus apps no avisan ni se abren."
        else -> "Perfil de trabajo · ${profile.apps.size} apps"
    }
    val action = when {
        private && profile.locked -> "Desbloquear"
        private -> "Bloquear"
        profile.locked -> "Reanudar"
        else -> "Pausar"
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(end = 24.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Ink.surface)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LineIcon(Glyph.LOCK, Ink.text, 20.dp)
        Text(state, style = Type.small.copy(color = Ink.text), modifier = Modifier.weight(1f))
        Chip(action, true, onToggle)
    }
}

/** Contacts or events matching the search: a heading, then one row each (a second line when there is one). */
@Composable
private fun Results(title: String, rows: List<Pair<String, String?>>, onOpen: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.semantics { heading() })
        rows.forEachIndexed { i, (main, detail) ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Ink.surface)
                    .clickable(role = Role.Button, onClick = { onOpen(i) })
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(main, style = Type.body)
                if (detail != null) Text(detail, style = Type.small)
            }
        }
    }
}

/** An event's start as the Petate shows it: "vie 21 nov · 20:30". */
object When {
    private val format = java.time.format.DateTimeFormatter.ofPattern("EEE d MMM · HH:mm", java.util.Locale.forLanguageTag("es-ES"))
    fun of(millis: Long, zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): String =
        format.format(java.time.Instant.ofEpochMilli(millis).atZone(zone)).replace(".", "")
}

/** Shortcuts whose name matches the search: the app's glyph, what it does, and whose it is. */
@Composable
private fun ShortcutResults(found: List<FoundShortcut>, onOpen: (FoundShortcut) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("ATAJOS", style = Type.cota.copy(fontSize = 10.sp), modifier = Modifier.semantics { heading() })
        found.forEach { f ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Ink.surface)
                    .clickable(role = Role.Button, onClick = { onOpen(f) })
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(Modifier.size(36.dp).clip(RoundedCornerShape(12.dp)).background(Ink.raised), contentAlignment = Alignment.Center) {
                    AppFace(f.app, Ink.tileTones[Pack.toneIndex(f.app, Ink.tileTones.size)])
                }
                Column(Modifier.weight(1f)) {
                    Text(f.shortcut.label, style = Type.body)
                    Text(f.app.label, style = Type.small)
                }
            }
        }
    }
}

/** The search field's sum or conversion, in large type; tapping copies it. */
@Composable
private fun Answer(text: String, onCopy: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(Ink.surface)
            .border(1.dp, Ink.field, RoundedCornerShape(20.dp))
            .clickable(role = Role.Button, onClickLabel = "Copiar", onClick = onCopy)
            .semantics(mergeDescendants = true) { contentDescription = "Copiar $text" }
            .padding(horizontal = 18.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("=", style = Type.title.copy(fontSize = 28.sp, color = Ink.primary))
        Text(text, style = Type.title.copy(fontSize = 28.sp, lineHeight = 32.sp, color = Brand.papel50), modifier = Modifier.weight(1f))
        Text("COPIAR", style = Type.cota.copy(fontSize = 10.sp))
    }
}

private val ALTIMETER = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ".toList()

/**
 * The altimeter: every letter as a mark on the right edge. Letters with apps jump there (tap or slide along it);
 * the rest are only marks, so TalkBack lists just the ones that go somewhere. [tight] is the phone on its side.
 */
@Composable
private fun Altimeter(present: Set<Char>, current: Char?, tight: Boolean = false, onJump: (Char) -> Unit) {
    var height by remember { mutableStateOf(1) }
    Column(
        Modifier
            .width(24.dp)
            .fillMaxHeight()
            .padding(bottom = if (tight) 8.dp else 16.dp)
            .strap()
            .onSizeChanged { height = it.height }
            .semantics { contentDescription = "Altímetro: desliza para saltar de letra" }
            .pointerInput(present) {
                detectVerticalDragGestures { change, _ ->
                    val i = (change.position.y / height * ALTIMETER.size).toInt().coerceIn(0, ALTIMETER.lastIndex)
                    ALTIMETER[i].takeIf { it in present }?.let(onJump)
                }
            },
        verticalArrangement = Arrangement.SpaceBetween,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // On its side there is no height to spare for the buckle: the letters need it all.
        if (!tight) Buckle()
        ALTIMETER.forEach { ch ->
            val on = ch == current
            val has = ch in present
            Row(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .then(if (has) Modifier.clickable(role = Role.Button, onClickLabel = "Saltar a la $ch") { onJump(ch) }.semantics { contentDescription = "Saltar a la $ch" } else Modifier.clearAndSetSemantics { }),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "$ch",
                    style = Type.mono.copy(fontSize = 10.sp, lineHeight = 10.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal),
                    color = when { on -> Ink.accentText; has -> Ink.textMuted; else -> Ink.field },
                )
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit, focus: FocusRequester, onFocus: (Boolean) -> Unit, height: androidx.compose.ui.unit.Dp = 50.dp, onGo: () -> Unit) {
    // The bag's mouth: dark inside, the cord's coral around it.
    Row(
        Modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(25.dp))
            .background(Ink.deep)
            .border(1.5.dp, Ink.primary, RoundedCornerShape(25.dp))
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LineIcon(Glyph.SEARCH, Ink.text, 20.dp)
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text("Busca en el petate", style = Type.body.copy(color = Ink.textMuted))
            BasicTextField(
                value = query,
                onValueChange = onChange,
                singleLine = true,
                textStyle = Type.body,
                cursorBrush = SolidColor(Ink.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { onGo() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus).onFocusChanged { onFocus(it.isFocused) }.semantics { contentDescription = "Buscar en el petate" },
            )
        }
    }
}

/** Filter chip: 36dp pill inside a 44dp touch target; selected = coral fill, never colour alone (weight changes too). */
@Composable
private fun Chip(text: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .heightIn(min = 44.dp)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { selected = on },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .height(36.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(if (on) Ink.primary else Ink.deep)
                .border(1.5.dp, if (on) Ink.primary else Ink.borderControl, RoundedCornerShape(999.dp))
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text,
                style = Type.body.copy(fontSize = 14.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Medium),
                color = if (on) Ink.onPrimary else Ink.text,
            )
        }
    }
}
