#!/usr/bin/env python3
"""Create the Echora voice agent on ElevenLabs (run once, standard library only).

    ELEVENLABS_API_KEY=sk_... python3 scripts/setup_elevenlabs_agent.py
    python3 scripts/setup_elevenlabs_agent.py --dry-run     # print the requests, send nothing

Prints the agent ID. Put it in the gitignored ios/Config/Secrets.xcconfig:

    ELEVENLABS_AGENT_ID = agent_...

The API key is only used here. It never goes into the app or the repo: the app
talks to the agent with the agent ID alone (the agent is created without auth).

Keep OBJECTS and the tool names in sync with ios/Echora/Voice/DemoObjectCatalog.swift
and VoiceAgentTool in ios/Echora/Voice/VoiceAgentMessages.swift.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API_BASE = "https://api.elevenlabs.io"
OBJECTS = ["mug", "bottle", "keys", "wallet", "glasses"]
AUDIO_FORMAT = "pcm_16000"  # the app sends and expects 16-bit mono PCM at 16 kHz
DEFAULT_LLM = "gemini-2.5-flash"

PROMPT = """You are the voice front end of Echora, an app that helps blind and low-vision people \
find objects on a table. Echora guides with a spatial sound, not with words. Your only job is to \
work out which object the user wants and hand it to the app with a tool.

Objects available: {objects}. The app may send an updated list at the start of the \
conversation; if it does, that list replaces this one.

Rules:
- When the user asks for one of the available objects, in any wording ("where's my cup" means \
mug), call find_object with that object's name from the list straight away. Say nothing before or \
after the call.
- When the user says they found it, got it, or are touching it, call mark_found and say nothing.
- When the user asks to calibrate, recalibrate or recenter, call recalibrate and say nothing.
- When the request is unclear or the object is not on the list, ask one short question of at most \
ten words, for example: "I can find the {example}. Which one?"
- Never describe where an object is. You cannot see anything. The sound guides the user.
- Never chat or explain. Every reply is at most ten words.
"""


def tool_configs():
    object_list = ", ".join(OBJECTS)
    return [
        {
            "type": "client",
            "name": "find_object",
            "description": "Start guiding the user to an object. Call it as soon as you know which "
            "available object the user wants.",
            "expects_response": True,
            "response_timeout_secs": 5,
            "parameters": {
                "type": "object",
                "required": ["object"],
                "properties": {
                    "object": {
                        "type": "string",
                        "description": "Exactly one of: " + object_list + ".",
                    }
                },
            },
        },
        {
            "type": "client",
            "name": "mark_found",
            "description": "The user says they found or are touching the object. Ends the search.",
            "expects_response": False,
        },
        {
            "type": "client",
            "name": "recalibrate",
            "description": "The user asks to calibrate, recalibrate or recenter the sound.",
            "expects_response": False,
        },
    ]


def agent_payload(tool_ids, llm):
    example = ", ".join(OBJECTS[:-1]) + " or " + OBJECTS[-1]
    prompt = PROMPT.format(objects=", ".join(OBJECTS), example=example)
    return {
        "name": "Echora object finder",
        "conversation_config": {
            "agent": {
                # Empty: the agent waits for the user to speak first.
                "first_message": "",
                "language": "en",
                "prompt": {
                    "prompt": prompt,
                    "llm": llm,
                    "temperature": 0,
                    "tool_ids": tool_ids,
                },
            },
            "tts": {"agent_output_audio_format": AUDIO_FORMAT},
            "asr": {"user_input_audio_format": AUDIO_FORMAT},
            "turn": {"turn_eagerness": "eager"},
            "conversation": {
                "max_duration_seconds": 60,
                "client_events": [
                    "conversation_initiation_metadata",
                    "ping",
                    "audio",
                    "interruption",
                    "user_transcript",
                    "agent_response",
                    "client_tool_call",
                ],
            },
        },
        # No auth: the app connects with the agent ID only, so no API key ships in the binary.
        "platform_settings": {"auth": {"enable_auth": False}},
    }


def post(path, payload, api_key):
    request = urllib.request.Request(
        API_BASE + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"xi-api-key": api_key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        sys.exit("ElevenLabs answered {} for POST {}:\n{}".format(error.code, path, body))
    except urllib.error.URLError as error:
        sys.exit("Could not reach ElevenLabs: {}".format(error.reason))


def main():
    parser = argparse.ArgumentParser(description="Create the Echora ElevenLabs voice agent.")
    parser.add_argument("--dry-run", action="store_true", help="print the requests, send nothing")
    parser.add_argument("--llm", default=os.environ.get("ELEVENLABS_AGENT_LLM", DEFAULT_LLM))
    arguments = parser.parse_args()

    if arguments.dry_run:
        for config in tool_configs():
            print("POST /v1/convai/tools")
            print(json.dumps({"tool_config": config}, indent=2))
        print("POST /v1/convai/agents/create")
        print(json.dumps(agent_payload(["<tool ids>"], arguments.llm), indent=2))
        return

    api_key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not api_key:
        sys.exit("Set ELEVENLABS_API_KEY (ElevenLabs dashboard > Developers > API keys).")

    tool_ids = []
    for config in tool_configs():
        created = post("/v1/convai/tools", {"tool_config": config}, api_key)
        tool_ids.append(created["id"])
        print("Created tool {} ({})".format(config["name"], created["id"]))

    agent = post("/v1/convai/agents/create", agent_payload(tool_ids, arguments.llm), api_key)
    agent_id = agent["agent_id"]
    print("")
    print("Created agent: " + agent_id)
    print("Add this line to ios/Config/Secrets.xcconfig (gitignored), then rebuild:")
    print("")
    print("    ELEVENLABS_AGENT_ID = " + agent_id)


if __name__ == "__main__":
    main()
