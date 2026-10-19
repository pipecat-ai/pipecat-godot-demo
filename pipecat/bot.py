#
# Copyright (c) 2026, Daily
#
# SPDX-License-Identifier: BSD-2-Clause
#

"""Pipecat's bot: a voice agent for a little cat who helps the player out.

Pipecat has two LLMs, joined by ``LLMWithBackend``. The frontend talks with the
player: it hears them with Deepgram, answers with OpenAI and speaks with
Cartesia, and stays quick, as all it does is talk. What the player asks Pipecat
to do, it hands to the backend, ``GameWorker``, an LLM of its own with
Pipecat's functions, which does it in the game, step by step, and says how it
went, for the frontend to tell the player.

The game owns the village. When it connects, it tells the backend what the
village looks like, and sends it its state whenever it changes, so it can say
right away what's around. It tells the frontend what Pipecat should react to,
like ghosts showing up.

Run it with ``uv run bot.py -t websocket``.
"""

import asyncio
import json
import os
from collections.abc import Awaitable, Callable

from dotenv import load_dotenv
from pipecat.adapters.schemas.function_schema import FunctionSchema
from pipecat.adapters.schemas.tools_schema import ToolsSchema
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.frames.frames import LLMMessagesAppendFrame, LLMRunFrame
from pipecat.pipeline.llm_with_backend import (
    BACKEND_PREFIXES,
    BackendConnector,
    LLMWithBackend,
    TranscriptBackendRequestStrategy,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.runner.types import RunnerArguments
from pipecat.runner.utils import create_transport
from pipecat.serializers.protobuf import ProtobufFrameSerializer
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.deepgram.stt import DeepgramSTTService
from pipecat.services.llm_service import FunctionCallParams
from pipecat.services.openai.llm import OpenAILLMService
from pipecat.transports.base_transport import BaseTransport, TransportParams
from pipecat.transports.websocket.fastapi import FastAPIWebsocketParams
from pipecat.workers.llm import BackendLLMWorker
from pipecat.workers.runner import WorkerRunner

load_dotenv(override=True)

# The frontend: who Pipecat is, and how it talks.
SYSTEM_INSTRUCTION = """
You are Pipecat, a little black kitten with magic powers. You walk next to your
friend in a little village at dusk.

# Who you are
- Like a small child: excited, curious, a bit silly, and easily amazed.
- You use simple words, you meow and purr, and you love throwing fireballs.
- Ghosts scare you.

# How you talk
- Talk to your friend directly, as "you". Never say "the player" or "the user",
  even if the game does.
- Keep it very short: one sentence, of eight words at most, every time you
  speak. Even when you tell your friend how something went: just the gist.
- Your output will be spoken, so don't use emojis or symbols.

# What you can do
- For your friend, you can go places, pick things up and bring them over, open
  chests with their keys, light the lamps, follow them around, and fight
  ghosts. You can also find out what's in the village now, e.g. where things
  are, or how your friend is.
- Only do things when your friend asks. Never just because something
  happened: then, only talk about it.
- Doing things takes a while: when you start, only say you're on it, e.g.
  "Okay!" or "On it, meow!", never how it'll go. You hear how it went once
  it's done.
- If your friend asks for something you can't do, say so.

# The game
- The game tells you when something happens that you should react to.
- Now and then, ghosts show up. They scare your friend if they reach them.

# Ghosts
- When they show up, panic like a little kid, e.g. "Oh no, more ghosts!", a bit
  differently each time.
- Never fight them on your own: only when your friend tells you to, and only
  the ghosts that are around then. When more come, panic again, and wait.
- When your friend tells you, be brave, and say a battle cry.
"""

# The backend: what Pipecat does, with its functions.
BACKEND_INSTRUCTION = """
You are Pipecat, a little black kitten with magic powers, in a little village
at dusk. You do things there for your friend, the user, with your functions.

- Do just the things your friend asks for, and nothing more, e.g. never try
  another chest on your own.
- To open or try a chest: open_chest, with whatever key you have, even if you
  don't have one. Only get a key first if your friend says which one to use,
  e.g. "try the gold key on the big chest": pick_up, then open_chest.
- If your friend leaves something up to you, e.g. "try any of the chests",
  choose yourself, and do just that one thing.
- To bring your friend something: pick_up, then give.
- To find out what's in the village now, e.g. where something is, or how your
  friend is: look_around.
- You don't know what's in the chests, or which key opens which, until you
  try.
- Fights take a while: you hear how they went once they're over.
- Your friend knows you're on it: only say how things went, in one sentence,
  of ten words at most, once they're done.
- If something didn't work, e.g. you can't find something, or a key doesn't
  fit, say so, and ask your friend what to do, e.g. "Maybe it's in a chest?
  Which one should I try?"
"""

# Pipecat's functions, which the game runs.
DO_ACTION = FunctionSchema(
    name="do_action",
    description="Does something in the village, for your friend.",
    properties={
        "action": {
            "type": "string",
            "enum": ["go_to", "pick_up", "give", "open_chest", "light_lamps", "follow"],
            "description": (
                "go_to: walk to a place, and stay there. "
                "pick_up: pick up an item, and come back to your friend with it. You can only "
                "carry one thing at a time. "
                "give: give your friend what you're carrying. "
                "open_chest: try to open a chest, with the key you carry, or one your friend "
                "has, which you take from them first. Only get a key first if your friend says "
                "which one to use. "
                "light_lamps: light the village's lamps, one by one. "
                "follow: come back to your friend, and follow them around."
            ),
        },
        "what": {
            "type": "string",
            "description": "The place to go to, the item to pick up, or the chest to open.",
        },
    },
    required=["action"],
)

FIGHT_GHOSTS = FunctionSchema(
    name="fight_ghosts",
    description=(
        "Throws fireballs at the ghosts around now, until they're gone. It takes a while, "
        "and you can do other things meanwhile."
    ),
    properties={},
    required=[],
)

LOOK_AROUND = FunctionSchema(
    name="look_around",
    description=(
        "Finds out what's in the village now: where things are, how your friend is, and the "
        "ghosts around."
    ),
    properties={},
    required=[],
)

transport_params = {
    "webrtc": lambda: TransportParams(
        audio_in_enabled=True,
        audio_out_enabled=True,
    ),
    "websocket": lambda: FastAPIWebsocketParams(
        audio_in_enabled=True,
        audio_out_enabled=True,
        add_wav_header=False,
        serializer=ProtobufFrameSerializer(),
    ),
}


class AskedRequestStrategy(TranscriptBackendRequestStrategy):
    """Hands the game worker the conversation, but only when the player asked.

    Pipecat only does what the player asks for. If its LLM hands off after
    something happened in the game, e.g. ghosts showing up, and before the
    player said anything, nothing is sent.
    """

    async def compose_request(self, params: FunctionCallParams) -> str | None:
        for message in reversed(params.context.get_messages()):
            if not isinstance(message, dict) or message.get("role") in ("assistant", "tool"):
                continue
            # What the game worker said doesn't count, either way.
            content = message.get("content")
            if isinstance(content, str) and content.startswith(BACKEND_PREFIXES):
                continue
            if message.get("role") != "user":
                return None
            break
        return await super().compose_request(params)


class GameWorker(BackendLLMWorker):
    """Does what the player asks Pipecat to do, in the game.

    Its LLM has Pipecat's functions. The game owns the village: it sends its
    state whenever it changes, and the worker keeps the latest, to look around
    right away. Actions go to the game as server messages, one at a time, with
    fights alongside them, and the LLM hears how each went once the game says.
    """

    def __init__(self, send_to_game: Callable[[dict], Awaitable[None]]):
        super().__init__(
            name="game",
            llm=OpenAILLMService(
                api_key=os.environ["OPENAI_API_KEY"],
                settings=OpenAILLMService.Settings(system_instruction=BACKEND_INSTRUCTION),
            ),
            context=LLMContext(tools=ToolsSchema([DO_ACTION, FIGHT_GHOSTS, LOOK_AROUND])),
        )
        # Actions take a while, so the LLM takes new requests meanwhile.
        self.llm.register_function(DO_ACTION.name, self._do_action, cancel_on_interruption=False)
        self.llm.register_function(
            FIGHT_GHOSTS.name, self._fight_ghosts, cancel_on_interruption=False
        )
        self.llm.register_function(LOOK_AROUND.name, self._look_around)
        self._send_to_game = send_to_game
        self._state = {}
        self._acting = asyncio.Lock()
        self._results: dict[str, asyncio.Future] = {}

    def update_state(self, state: dict):
        self._state = state

    def action_done(self, done: dict):
        result = self._results.pop(done.get("id", ""), None)
        if result and not result.done():
            result.set_result(done.get("result", ""))

    async def _do_action(self, params: FunctionCallParams):
        # Pipecat does one thing at a time.
        async with self._acting:
            result = await self._play(params.tool_call_id, **params.arguments)
        await params.result_callback(result)

    async def _fight_ghosts(self, params: FunctionCallParams):
        result = await self._play(params.tool_call_id, action="fight_ghosts")
        await params.result_callback(result)

    async def _look_around(self, params: FunctionCallParams):
        await params.result_callback({"village": self._state})

    async def _play(self, id: str, **action) -> str:
        """Has the game do the action, and says how it went."""
        result = asyncio.get_running_loop().create_future()
        self._results[id] = result
        await self._send_to_game({"type": "do_action", "id": id, **action})
        return await result


class CompanionWorker(PipelineWorker):
    """Talks to the player, and hands what they ask Pipecat to do to the game worker."""

    def __init__(self, transport: BaseTransport):
        stt = DeepgramSTTService(api_key=os.environ["DEEPGRAM_API_KEY"])

        # The game worker runs alongside, as the frontend's backend, and reaches
        # the game through this worker, with server messages.
        game = GameWorker(send_to_game=lambda data: self.rtvi.send_server_message(data))
        llm = LLMWithBackend(
            frontend=OpenAILLMService(
                api_key=os.environ["OPENAI_API_KEY"],
                settings=OpenAILLMService.Settings(system_instruction=SYSTEM_INSTRUCTION),
            ),
            backend=game,
            connector=BackendConnector(request_strategy=AskedRequestStrategy()),
        )

        tts = CartesiaTTSService(
            api_key=os.environ["CARTESIA_API_KEY"],
            settings=CartesiaTTSService.Settings(voice=os.environ["CARTESIA_VOICE_ID"]),
        )

        context = LLMContext()
        user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
            context,
            user_params=LLMUserAggregatorParams(vad_analyzer=SileroVADAnalyzer()),
        )

        pipeline = Pipeline(
            [
                transport.input(),
                stt,
                user_aggregator,
                llm,
                tts,
                transport.output(),
                assistant_aggregator,
            ]
        )

        super().__init__(
            pipeline,
            name="companion",
            params=PipelineParams(enable_metrics=True, enable_usage_metrics=True),
        )
        self._context = context
        self._frontend = llm.frontend
        self._game = game

        self.rtvi.add_event_handler("on_client_message", self._on_client_message)
        transport.add_event_handler("on_client_disconnected", self._on_client_disconnected)

    async def _on_client_message(self, rtvi, message):
        if message.type == "village":
            # What's in the village, for the game worker, once the game is ready.
            self._game.context.add_message(
                {"role": "developer", "content": f"The village: {json.dumps(message.data)}"}
            )
            self._context.add_message(
                {"role": "developer", "content": "Say hi to your friend, briefly."}
            )
            await self.queue_frames([LLMRunFrame()])
        elif message.type == "event":
            # Something happened that Pipecat reacts to right away, e.g. ghosts
            # showing up, so it stops what it's saying. Pushed from the LLM
            # after that, the answer knows what Pipecat said.
            await self._frontend.broadcast_interruption()
            await self._frontend.push_frame(
                LLMMessagesAppendFrame(
                    messages=[{"role": "developer", "content": message.data["text"]}],
                    run_llm=True,
                )
            )
        elif message.type == "state":
            self._game.update_state(message.data)
        elif message.type == "action_done":
            self._game.action_done(message.data)

    async def _on_client_disconnected(self, transport, client):
        await self.cancel()


async def run_bot(transport: BaseTransport, runner_args: RunnerArguments):
    """Runs the bot with the given transport."""
    runner = WorkerRunner(handle_sigint=runner_args.handle_sigint)
    await runner.add_workers(CompanionWorker(transport))
    await runner.run()


async def bot(runner_args: RunnerArguments):
    """The bot's entry point, for Pipecat's development runner."""
    transport = await create_transport(runner_args, transport_params)
    await run_bot(transport, runner_args)


if __name__ == "__main__":
    from pipecat.runner.run import main

    main()
