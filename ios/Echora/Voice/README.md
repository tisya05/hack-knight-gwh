# Voice agent (ElevenLabs) + fixed demo objects

Hold push-to-talk and talk to an ElevenLabs agent. The agent works out which object you want and
calls a tool; the app sets the sound target to that object's fixed spot. No Gemini involved.

```
hold push-to-talk
   -> ElevenLabsVoiceListener opens a conversation, streams the mic
   -> agent calls find_object("mug")          (asks "which one?" if unclear)
   -> stopListening() returns "mug"           (coordinator sees a normal transcript)
   -> DemoObjectLocator returns the mug's fixed box in the camera frame
   -> PerceptionService.place puts it on the real surface there -> audio.setTarget
```

`mark_found` and `recalibrate` come back as the "found" / "calibrate" voice commands (CONTRACT 3.6),
so they work mid-round like before. Nothing in `Contracts/` or the coordinator changes.

## Fixed objects

`DemoObjectCatalog.swift`. Each object owns a spot in the camera frame (phone upright, looking at the table):

```
  mug            bottle
         keys
  wallet         glasses
```

Put the real objects roughly there, or just use the spots to test audio and head tracking.
With mock perception every object lands on the mock's single fixed point.
To change the set, edit the catalog and `OBJECTS` in `scripts/setup_elevenlabs_agent.py`, then create a new agent.

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
   ECHORA_REAL_SERVICES = perception audio headTracking voice demoObjects
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
  ```
- A hold-to-talk control that calls `beginVoiceRequest` / `endVoiceRequest` (Qimin's `OperatorView` / `UserModeView`).

## Testing on the phone

- A line at the top of the screen shows what is happening: `connecting…`, `listening`, `heard "..."`,
  `find_object -> mug`. Off with launch argument `-voice.debugOverlay NO`.
- Console categories: `VoiceAgent`, `VoiceAgentAudio`, `VoiceAgentSocket`, `DemoLocator`.
- After release the app waits for the agent up to 8 s without activity (30 s hard stop). If the agent
  never decides, the last thing you said is used as the transcript.
- On the phone speaker the mic is silenced while the agent talks (it would hear itself). With
  earphones you can talk over it.
- Check first: the cue and earcons still play cleanly while the mic is open (the agent uses its own
  `AVAudioEngine` next to the spatial one, CONTRACT 4.5).
