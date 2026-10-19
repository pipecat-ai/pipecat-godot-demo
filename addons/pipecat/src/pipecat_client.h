//
// Copyright (c) 2026, Daily
//
// SPDX-License-Identifier: BSD-2-Clause
//

#ifndef PIPECAT_GODOT_CLIENT_H
#define PIPECAT_GODOT_CLIENT_H

#include <godot_cpp/classes/audio_effect_capture.hpp>
#include <godot_cpp/classes/audio_stream_generator_playback.hpp>
#include <godot_cpp/classes/audio_stream_player.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <functional>
#include <memory>

class PipecatSession;

namespace godot {

// A function the bot's LLM called, for the game to run. The game answers with
// respond(), right away or later, e.g. once something in the game is done.
class PipecatFunctionCall : public RefCounted {
    GDCLASS(PipecatFunctionCall, RefCounted)

   public:
    String get_function_name() const { return function_name; }
    Dictionary get_arguments() const { return arguments; }

    // Sends the bot the result, e.g. a String or a Dictionary. Only the first
    // result is sent.
    void respond(const Variant& result);

    String function_name;
    Dictionary arguments;
    std::function<void(const Variant&)> send_result;

   protected:
    static void _bind_methods();
};

// Talks to a Pipecat bot with voice: starts the bot, sends it the microphone,
// and plays its voice.
//
// Its signals are emitted on the main thread.
class PipecatClient : public Node {
    GDCLASS(PipecatClient, Node)

   public:
    PipecatClient();
    ~PipecatClient() override;

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    // Starts the bot and connects to it, without waiting. bot_ready is emitted
    // once it's ready.
    void connect_to_bot();
    void disconnect_from_bot();
    bool is_bot_ready() const;

    // Sends text to the bot, as if the user said it.
    void send_text(const String& text);
    // Sends the bot a message of the game's own, with data that can be JSON.
    void send_client_message(const String& type, const Variant& data);

    // How loud the bot's voice and the microphone are right now, from 0 to 1.
    float get_bot_voice_level() const;
    float get_microphone_level() const;

    void set_start_url(const String& url) { start_url = url; }
    String get_start_url() const { return start_url; }
    void set_api_key(const String& key) { api_key = key; }
    String get_api_key() const { return api_key; }
    void set_connect_on_ready(bool enabled) { connect_on_ready = enabled; }
    bool get_connect_on_ready() const { return connect_on_ready; }
    void set_use_microphone(bool enabled) { use_microphone = enabled; }
    bool get_use_microphone() const { return use_microphone; }

   protected:
    static void _bind_methods();

   private:
    void start_microphone();
    void stop_microphone();

    String start_url = "http://localhost:7860/start";
    String api_key;
    bool connect_on_ready = true;
    bool use_microphone = true;

    AudioStreamPlayer* voice = nullptr;
    Ref<AudioStreamGeneratorPlayback> voice_playback;
    AudioStreamPlayer* microphone = nullptr;
    Ref<AudioEffectCapture> microphone_capture;
    std::unique_ptr<PipecatSession> session;
};

}  // namespace godot

#endif
