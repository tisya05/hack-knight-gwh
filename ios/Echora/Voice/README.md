# Voice: say the object, hear whether it was found

```
hold push-to-talk, say "where's my mug", release
   -> VoiceCommandListener (on-device speech, CONTRACT 4.5) returns the transcript
   -> coordinator captures a snapshot and asks the locator (Gemini) for that object
        not in the camera's view -> "Object not found. Please turn."  (then the not-found earcon, no round)
        in view                  -> "Item found."                     (then the beeping starts)
```

- `VoiceCommandListener` + `AppleSpeechBackend`: `SFSpeechRecognizer` on its own `AVAudioEngine` input
  tap, on-device when the phone supports it. Release returns the final wording, or the best partial
  after 1 s. The microphone closes by itself 6 s after the press. "found" / "calibrate" keep working
  (the coordinator handles them).
- `AnnouncingLocator` wraps whichever locator is in use and speaks with the on-device voice
  (`AVSpeechSynthesizer`). Guidance starts only when "Item found." has ended; the round timer still
  starts with the cue. Timeouts and network errors stay silent. Change the wording in `AnnouncingLocator`.

No API key and no new Info.plist keys (the microphone and speech descriptions already exist).

## Switching it on

In the gitignored `ios/Config/Local.xcconfig`:

```
ECHORA_REAL_SERVICES = perception locator audio headTracking voice announcements
```

- `voice` needs `audio`: the Audio module owns the audio session and enables the microphone. Device only.
- `locator` needs `GEMINI_API_KEY` in `Secrets.xcconfig`. Without it the mock locator answers: it
  "finds" everything except a request containing "unicorn", which is a quick way to hear the not-found phrase.
- `announcements` is off unless listed (or launch argument `-flag.announcements YES`).

## Wiring this needs outside `Voice/`

Not on this branch (Tisya owns `App/`). Verified to build and pass tests when applied:

```swift
// AppEnvironment.make(flags:)
let baseLocator = makeLocator(useMock: flags.mockLocator, logger: logger)
let locator = AnnouncingLocator.wrapIfEnabled(baseLocator)
let voice = makeVoice(useMock: flags.mockVoice, logger: logger)

private static func makeVoice(useMock: Bool, logger: Logger) -> VoiceCommandListening {
    if useMock {
        return MockVoiceListener()
    }
    logger.info("Using real VoiceCommandListener (on-device speech)")
    return VoiceCommandListener(backend: AppleSpeechBackend())
}
```

Plus a hold-to-talk control calling `beginVoiceRequest` / `endVoiceRequest` (Qimin's `OperatorView` / `UserModeView`).

## Testing on the phone

- The status line shows `Listening…`, then `Locating "<what was heard>"…`, so a wrong transcript is visible at once.
- Console categories: `VoiceListener`, `SpeechBackend`, `Announcer`.
- Ask for an object on the table ("Item found.", then beeping). Turn away from it and ask again
  ("Object not found. Please turn.").
- Check first: the cue and earcons still play cleanly while the microphone is open (voice uses its
  own `AVAudioEngine` next to the spatial one), and the spoken phrases come through the AirPods.
