extends Node
## Generic localization singleton (autoloaded as "Translations").
##
## Loads one JSON dictionary per locale from res://translations/<locale>.json,
## where each file maps a stable string key to its localized text. Look up a
## string with Translations.t("some.key"). Missing keys fall back to the
## fallback locale, then to the key itself, so a forgotten translation is
## visible rather than blank.
##
## To add a language: drop a new <locale>.json next to the existing ones and
## add its code to SUPPORTED_LOCALES.

## Emitted whenever the active locale changes. UI listening to this should
## re-fetch its strings.
signal locale_changed(locale: String)

const TRANSLATIONS_DIR: String = "res://translations/"
## Locales shipped with the game. Listed explicitly (rather than scanning the
## directory) so loading stays reliable in exported builds.
const SUPPORTED_LOCALES: PackedStringArray = ["en", "fr"]
## The game starts in French.
const DEFAULT_LOCALE: String = "fr"
## Used to resolve keys missing from the active locale.
const FALLBACK_LOCALE: String = "en"

var _locale: String = DEFAULT_LOCALE
var _tables: Dictionary = {}  # locale -> Dictionary(key -> String)


func _ready() -> void:
	_load_all()
	set_locale(DEFAULT_LOCALE)


func _load_all() -> void:
	_tables.clear()
	for locale: String in SUPPORTED_LOCALES:
		_tables[locale] = _load_table(TRANSLATIONS_DIR + locale + ".json")


func _load_table(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Translations: cannot read %s" % path)
		return {}
	var json: JSON = JSON.new()
	var error: Error = json.parse(file.get_as_text())
	file.close()
	if error != OK or not (json.data is Dictionary):
		push_warning("Translations: invalid JSON in %s" % path)
		return {}
	return json.data as Dictionary


## The currently active locale code, e.g. "fr".
func get_locale() -> String:
	return _locale


## Switch the active locale. Unknown locales are ignored with a warning.
func set_locale(locale: String) -> void:
	if not _tables.has(locale):
		push_warning("Translations: locale '%s' is not loaded; keeping '%s'" % [locale, _locale])
		return
	if _locale == locale:
		return
	_locale = locale
	locale_changed.emit(_locale)


## Translate a key into the active locale. Falls back to the fallback locale,
## then to the key itself when no translation exists.
func t(key: String) -> String:
	var table: Dictionary = _tables.get(_locale, {}) as Dictionary
	if table.has(key):
		return str(table[key])
	var fallback: Dictionary = _tables.get(FALLBACK_LOCALE, {}) as Dictionary
	if fallback.has(key):
		return str(fallback[key])
	return key
