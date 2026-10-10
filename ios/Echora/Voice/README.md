# Voice agent (ElevenLabs) + fixed demo objects

Hold push-to-talk and talk to an ElevenLabs agent. The agent works out which object you want and
calls a tool; the app sets the sound target to that object's fixed place. No Gemini involved.

```
hold push-to-talk
   -> ElevenLabsVoiceListener opens a conversation, streams the mic
   -> agent calls find_object("mug")          (asks "which one?" if unclear)
   -> stopListening() returns "mug"           (coordinator sees a normal transcript)
   -> DemoObjectLocator: is the mug's fixed place in the camera's view?
        no  -> "Object not found. Please turn."  (then the not-found earcon, no round)
        yes -> "Item found."                     (then the beeping starts)
   -> PerceptionService.place puts it on the real surface there -> audio.setTarget
```

`mark_found` and `recalibrate` come back as the "found" / "calibrate" voice commands (CONTRACT 3.6),
so they work mid-round like before. Nothing in `Contracts/` or the coordinator changes.

## Fixed objects

`DemoObjectCatalog.swift`. Each object sits at a fixed place in the room, measured from where the
phone was when the app started (seen from above, phone facing up the page):

```
  mug            bottle       0.60 m ahead
         keys                 0.50 m
  wallet         glasses      0.40 m
        (phone)               all 0.30 m below the phone, 0.18 m to each side
```

So start the app holding the phone upright at chest height, pointed at the table. Like a real
detector, the locator only finds an object when the camera is looking at its place: turn or point
away and the request fails with `.objectNotFound`.
With mock perception the camera never moves and looks straight ahead, so nothing is in view.
To change the set, edit the catalog and `OBJECTS` in `scripts/setup_elevenlabs_agent.py`, then create a new agent.

## Spoken announcements

`AnnouncingLocator` wraps whichever locator is in use (demo objects now, Gemini later) and speaks with
the on-device voice (`AVSpeechSynthesizer`, no key, no network):

- "Item found." after a successful locate. Guidance starts only when the words have ended, and the
  round timer starts with the cue as before.
- "Object not found. Please turn." on `.objectNotFound`. Timeouts and network errors stay silent.

Change the wording in `AnnouncingLocator`. Off unless `announcements` is switched on (below).

## Setup

1. Create the agent once (the API key is only used by this script, never by the app):
   ```bash
   ELEVENLABS_API_KEY=sk_... python3 scripts/setup_elevenlabs_agent.py
   ```
2. Put the printed ID in the gitignored `ios/Config/Secrets.xcconfig`:
   ```
   ELEVENLABS_AGENT_ID = agent_...
   ```
3. In the gitignored `ios/Config/Local.xcconfig`:
   ```
   ECHORA_REAL_SERVICES = perception audio headTracking voice demoObjects announcements
   ```
   `voice` needs `audio` (the Audio module owns the audio session and enables the mic). Device only.
4. `xcodegen generate`, build to the phone.

The agent has no auth, so the agent ID alone starts a conversation on our account: keep it out of the repo.

## Wiring this needs outside `Voice/`

Not on this branch (owners: Tisya for `App/`, `Info.plist`, `ios/Config/`). Verified to build and pass tests when applied:

- `ios/Config/Base.xcconfig`: add `ELEVENLABS_AGENT_ID =` next to the other defaults.
- `ios/Config/Secrets.xcconfig.example`: add `ELEVENLABS_AGENT_ID = agent_xxxxxxxx`.
- `ios/Echora/Info.plist`: add key `ELEVENLABS_AGENT_ID` = `$(ELEVENLABS_AGENT_ID)`.
- `ios/Echora/App/AppEnvironment.swift`:
  ```swift
  // in make(flags:), replacing the hard-coded MockVoiceListener()
  let voice = makeVoice(useMock: flags.mockVoice, logger: logger)

  private static func makeVoice(useMock: Bool, logger: Logger) -> VoiceCommandListening {
      if useMock {
          return MockVoiceListener()
      }
      guard let agent = ElevenLabsVoiceListener.makeFromBundle() else {
          logger.warning("Real voice requested but ELEVENLABS_AGENT_ID is empty (ios/Config/Secrets.xcconfig). Using mock.")
          return MockVoiceListener()
      }
      logger.info("Using real ElevenLabsVoiceListener")
      return agent
  }

  // first lines of makeLocator(useMock:logger:)
  if DemoObjectLocator.isEnabled() {
      logger.info("Using DemoObjectLocator (fixed demo objects, no Gemini)")
      return DemoObjectLocator()
  }

  // in make(flags:), replacing `let locator = makeLocator(...)`
  let baseLocator = makeLocator(useMock: flags.mockLocator, logger: logger)
  let locator = AnnouncingLocator.wrapIfEnabled(baseLocator)
  ```
- A hold-to-talk control that calls `beginVoiceRequest` / `endVoiceRequest` (Qimin's `OperatorView` / `UserModeView`).

## Testing on the phone

- A line at the top of the screen shows what is happening: `connecting…`, `listening`, `heard "..."`,
  `find_object -> mug`. Off with launch argument `-voice.debugOverlay NO`.
- Console categories: `VoiceAgent`, `VoiceAgentAudio`, `VoiceAgentSocket`, `DemoLocator`, `Announcer`.
- Ask for the mug facing the table ("Item found.", then beeping), then turn a quarter turn and ask
  again ("Object not found. Please turn.").
- After release the app waits for the agent up to 8 s without activity (30 s hard stop). If the agent
  never decides, the last thing you said is used as the transcript.
- On the phone speaker the mic is silenced while the agent talks (it would hear itself). With
  earphones you can talk over it.
- Check first: the cue and earcons still play cleanly while the mic is open (the agent uses its own
  `AVAudioEngine` next to the spatial one, CONTRACT 4.5).
