# Localization

## Language selection

Settings → General → Language provides Automatic, Polski and English. Automatic selects Polish when the primary system language is Polish and English otherwise. Explicit selections override the system language.

The iOS app, widget and Intents extension share the `appLanguage` preference through the app group. Watch receives the preference through WatchConnectivity, using durable application context and retries after activation, installation and reachability changes. App-owned text follows this preference; system dialogs and Siri's voice follow operating-system settings and capabilities.

## Resources and UI

[`Shared/Localization.swift`](../Shared/Localization.swift) is compiled into the app, extensions and WorkoutDataKit. It provides `AppLanguage`, `L10n.string`, `L10n.format`, the selected locale and language-change notifications. Resources in `Shared/en.lproj` and `Shared/pl.lproj` contain UI strings, plural rules and Siri intent templates.

When adding or changing text:

1. Add matching English and Polish resource keys, preserving format argument types and intent variables.
2. Use the selected locale for SwiftUI localized text and Foundation formatting. Use `L10n.string` or `L10n.format` for dynamic strings outside SwiftUI, such as UIKit labels, notifications and Siri responses.
3. Keep resources available in every target that uses them. Test live language changes without losing navigation or draft state.
4. Run the localization validator and relevant tests described in [Testing](testing.md).

Missing localized strings fall back to English, then to the resource key.

## Exercise catalog and stored data

The English catalog in [`WorkoutDataKit/everkinetic-data`](../WorkoutDataKit/everkinetic-data) supplies canonical exercise data. `exercises-pl.json` contains Polish titles, aliases, introductions, ordered instructions and tips, matched by UUID. Search uses both English and Polish titles and aliases regardless of display language, ignoring case, accents, `ł` and surrounding whitespace.

Keep UUIDs, numeric IDs, muscle and equipment keys, references and image/PDF paths unchanged when editing translations. User-authored exercise content, workout names and comments retain their original text.

[`Exercise`](../WorkoutDataKit/Model/Exercise.swift) exposes localized presentation fields while encoding the original catalog values. Workout and routine exercise references serialize `canonicalTitle` into `exerciseName`; display-language changes must not alter backup or JSON export payloads. Preserve this distinction when adding serialization paths.

Some source entries have empty content: ID 239 begins with an HTML-only `&nbsp;` slot, and IDs 237 and 291 have empty introductions. Preserve source structure when maintaining translations; the validator distinguishes these entries from missing translated instructions.

## Polish terminology

Use Polish Wikipedia as the terminology reference when maintaining the Polish catalog. These references cover the anatomical and exercise terms used in the translations:

- Muscles: [mięsień naramienny](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_naramienny), [trójgłowy ramienia](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_tr%C3%B3jg%C5%82owy_ramienia), [dwugłowy ramienia](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_dwug%C5%82owy_ramienia), [najszerszy grzbietu](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_najszerszy_grzbietu), [czworoboczny](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_czworoboczny), [piersiowy większy](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_piersiowy_wi%C4%99kszy), [czworogłowy uda](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_czworog%C5%82owy_uda), [brzuchaty łydki](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_brzuchaty_%C5%82ydki), [płaszczkowaty](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_p%C5%82aszczkowaty), [pośladkowy wielki](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_po%C5%9Bladkowy_wielki) and [prostownik grzbietu](https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_prostownik_grzbietu).
- Exercises: [przysiad](https://pl.wikipedia.org/wiki/Przysiad), [martwy ciąg](https://pl.wikipedia.org/wiki/Martwy_ci%C4%85g), [podciąganie](https://pl.wikipedia.org/wiki/Podci%C4%85ganie_na_dr%C4%85%C5%BCku), [deska](https://pl.wikipedia.org/wiki/Plank), [pompki na poręczach](https://pl.wikipedia.org/wiki/Pompki_na_por%C4%99czach) and [wznosy bokiem](https://pl.wikipedia.org/wiki/Wznosy_bokiem).
- Equipment: [hantle](https://pl.wikipedia.org/wiki/Hantle) and [sztanga](https://pl.wikipedia.org/wiki/Sztanga).
