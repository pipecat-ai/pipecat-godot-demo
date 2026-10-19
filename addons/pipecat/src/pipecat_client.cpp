//
// Copyright (c) 2026, Daily
//
// SPDX-License-Identifier: BSD-2-Clause
//

#include "pipecat_client.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/audio_stream_generator.hpp>
#include <godot_cpp/classes/audio_stream_microphone.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <pipecat/pipecat.h>
#include <pipecat/websocket/transport.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using namespace godot;

namespace {

// The microphone is sent at 16 kHz, like most speech-to-text services use.
const uint32_t USER_SAMPLE_RATE = 16000;
// The transport sends it 10 ms at a time.
const size_t USER_CHUNK_FRAMES = USER_SAMPLE_RATE / 100;

// The most bot voice Godot has waiting to be played, in seconds. The bot sends
// its voice faster than it plays, so it's read as Godot needs it.
const float BOT_VOICE_BUFFER_LENGTH = 0.1f;

// The bus Godot captures the microphone from.
const char* MICROPHONE_BUS = "PipecatMicrophone";

String to_godot(const std::string& text) {
    return String::utf8(text.c_str());
}

std::string to_std(const String& text) {
    return text.utf8().get_data();
}

// JSON goes through text, which Godot and nlohmann/json both read.
Variant to_variant(const nlohmann::json& json) {
    return JSON::parse_string(to_godot(json.dump()));
}

nlohmann::json to_json(const Variant& value) {
    return nlohmann::json::parse(to_std(JSON::stringify(value)));
}

float loudness(const int16_t* frames, size_t num_frames) {
    double sum = 0.0;
    for (size_t i = 0; i < num_frames; ++i) {
        sum += double(frames[i]) * frames[i];
    }
    float rms = num_frames > 0 ? float(std::sqrt(sum / num_frames) / 32768.0)
                               : 0.0f;
    return std::clamp(rms * 4.0f, 0.0f, 1.0f);
}

}  // namespace

// Everything that talks to Pipecat. Pipecat calls its callbacks on the client's
// own thread, and they're queued for the node, which emits its signals on the
// main thread.
class PipecatSession : public pipecat::PipecatClientCallbacks {
   public:
    using Event = std::function<void(PipecatClient&)>;

    PipecatSession(uint32_t mix_rate, Ref<AudioStreamGeneratorPlayback> voice)
        : mix_rate(mix_rate), voice(voice) {
        pipecat::WebSocketTransportOptions transport_options;
        transport_options.user_audio_sample_rate = USER_SAMPLE_RATE;
        transport_options.user_audio_channels = 1;
        // The bot's voice comes at Godot's mix rate, ready to play.
        transport_options.bot_audio_sample_rate = mix_rate;
        transport_options.bot_audio_channels = 1;

        pipecat::PipecatClientOptions options;
        options.transport = std::make_unique<pipecat::WebSocketTransport>(
                transport_options
        );
        options.callbacks = this;
        client = std::make_unique<pipecat::PipecatClient>(std::move(options));

        running = true;
        reader = std::thread([this] { play_bot_voice(); });
    }

    ~PipecatSession() override { stop(); }

    void start(const String& start_url, const String& api_key) {
        pipecat::APIRequest request;
        request.endpoint = to_std(start_url);
        request.request_data = {{"transport", "websocket"}};
        if (!api_key.is_empty()) {
            request.headers["Authorization"] = "Bearer " + to_std(api_key);
        }

        // Starting the bot and connecting take a few seconds.
        connector = std::thread([this, request] {
            try {
                client->start_bot_and_connect(request);
            } catch (const std::exception&) {
                // The client reports why, with on_error().
            }
        });
    }

    void stop() {
        if (!running.exchange(false)) {
            return;
        }
        // Also stops a connection in progress, and wakes up the reader.
        client->disconnect();
        if (connector.joinable()) {
            connector.join();
        }
        if (reader.joinable()) {
            reader.join();
        }
        ready = false;
    }

    void send_text(const String& text) {
        try {
            client->send_text(to_std(text));
        } catch (const std::exception& error) {
            report_error(std::string("Unable to send text: ") + error.what());
        }
    }

    void send_client_message(const String& type, const Variant& data) {
        try {
            client->send_client_message(to_std(type), to_json(data));
        } catch (const std::exception& error) {
            report_error(
                    std::string("Unable to send a message: ") + error.what()
            );
        }
    }

    // Sends the microphone, as Godot captures it, at 16 kHz. Each sample is
    // the average of the ones it replaces, which also leaves out the sounds
    // too high for 16 kHz.
    void send_microphone(const PackedVector2Array& frames) {
        double step = double(mix_rate) / USER_SAMPLE_RATE;
        const Vector2* data = frames.ptr();
        for (int64_t i = 0; i < frames.size(); ++i) {
            microphone_sum += (data[i].x + data[i].y) * 0.5;
            microphone_count += 1;
            microphone_position += 1.0;
            if (microphone_position >= step) {
                microphone_position -= step;
                double sample = std::clamp(
                        microphone_sum / microphone_count, -1.0, 1.0
                );
                microphone_pending.push_back(int16_t(sample * 32767.0));
                microphone_sum = 0.0;
                microphone_count = 0;
            }
        }

        size_t sent = 0;
        while (microphone_pending.size() - sent >= USER_CHUNK_FRAMES) {
            const int16_t* chunk = microphone_pending.data() + sent;
            microphone_level = loudness(chunk, USER_CHUNK_FRAMES);
            // Does nothing until it's connected.
            client->send_user_audio(chunk, USER_CHUNK_FRAMES);
            sent += USER_CHUNK_FRAMES;
        }
        microphone_pending.erase(
                microphone_pending.begin(), microphone_pending.begin() + sent
        );
    }

    std::vector<Event> take_events() {
        std::lock_guard<std::mutex> lock(events_mutex);
        return std::exchange(events, {});
    }

    bool is_ready() const { return ready; }
    float get_bot_voice_level() const { return bot_level; }
    float get_microphone_level() const { return microphone_level; }

    //
    // pipecat::PipecatClientCallbacks, on the client's thread.
    //

    void on_bot_ready(const pipecat::rtvi::BotReadyData&) override {
        ready = true;
        emit("bot_ready");
    }

    void on_disconnected() override {
        ready = false;
        emit("disconnected");
    }

    void on_error(const pipecat::rtvi::ErrorData& error) override {
        report_error(error.error);
    }

    void on_user_started_speaking() override { emit("user_started_speaking"); }

    void on_user_stopped_speaking() override { emit("user_stopped_speaking"); }

    void on_user_input(const pipecat::rtvi::UserInputData& data) override {
        std::string text = data.text;
        bool final = data.final;
        post([text, final](PipecatClient& node) {
            node.emit_signal("user_transcript", to_godot(text), final);
        });
    }

    void on_bot_started_speaking() override { emit("bot_started_speaking"); }

    void on_bot_stopped_speaking() override {
        // The bot doesn't send silence, so its voice isn't read until it
        // speaks again.
        bot_level = 0.0f;
        emit("bot_stopped_speaking");
    }

    void on_bot_interrupted() override { emit("bot_interrupted"); }

    void on_bot_output(const pipecat::rtvi::BotOutputData& data) override {
        // Text the bot speaks comes first when it's written, and then again as
        // it's spoken. Pass it on once, when the bot starts speaking it, so it
        // matches the voice.
        if (data.will_be_spoken.value_or(false) &&
            data.spoken_status == std::optional<std::string>("new")) {
            return;
        }
        if (data.segment_id &&
            !output_segments.insert(*data.segment_id).second) {
            return;
        }
        std::string text = data.text;
        post([text](PipecatClient& node) {
            String stripped = to_godot(text).strip_edges();
            // E.g. a paragraph break.
            if (!stripped.is_empty()) {
                node.emit_signal("bot_output", stripped);
            }
        });
    }

    void on_server_message(const nlohmann::json& data) override {
        post([data](PipecatClient& node) {
            node.emit_signal("server_message", to_variant(data));
        });
    }

    void on_llm_function_call_in_progress(
            const pipecat::rtvi::LLMFunctionCallInProgressData& data,
            pipecat::FunctionCallResultCallback respond
    ) override {
        // Without a name, it's one the bot keeps to itself.
        if (!data.function_name) {
            return;
        }
        std::string name = *data.function_name;
        nlohmann::json arguments = data.arguments;
        post([name, arguments, respond](PipecatClient& node) {
            Ref<PipecatFunctionCall> call;
            call.instantiate();
            call->function_name = to_godot(name);
            call->arguments = to_variant(arguments);
            call->send_result = [respond](const Variant& result) {
                respond(to_json(result));
            };
            node.emit_signal("function_call", call);
        });
    }

   private:
    void post(Event event) {
        std::lock_guard<std::mutex> lock(events_mutex);
        events.push_back(std::move(event));
    }

    void emit(const char* signal) {
        post([signal](PipecatClient& node) { node.emit_signal(signal); });
    }

    void report_error(const std::string& error) {
        post([error](PipecatClient& node) {
            UtilityFunctions::push_warning("Pipecat: ", to_godot(error));
            node.emit_signal("error", to_godot(error));
        });
    }

    // Reads the bot's voice and queues it on the generator Godot plays.
    void play_bot_voice() {
        const size_t chunk_frames = mix_rate / 100;
        std::vector<int16_t> frames(chunk_frames);
        PackedVector2Array buffer;
        while (running) {
            if (voice->get_frames_available() < int32_t(chunk_frames)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }
            int32_t read = client->read_bot_audio(frames.data(), frames.size());
            if (read <= 0) {
                // Not connected.
                bot_level = 0.0f;
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }
            bot_level = loudness(frames.data(), read);
            buffer.resize(read);
            Vector2* samples = buffer.ptrw();
            for (int32_t i = 0; i < read; ++i) {
                float sample = frames[i] / 32768.0f;
                samples[i] = Vector2(sample, sample);
            }
            voice->push_buffer(buffer);
        }
    }

    const uint32_t mix_rate;
    Ref<AudioStreamGeneratorPlayback> voice;

    std::atomic<bool> running {false};
    std::atomic<bool> ready {false};
    std::atomic<float> bot_level {0.0f};
    std::atomic<float> microphone_level {0.0f};

    std::mutex events_mutex;
    std::vector<Event> events;

    // Only used on the client's thread.
    std::set<int64_t> output_segments;

    // Only used on the main thread.
    std::vector<int16_t> microphone_pending;
    double microphone_sum = 0.0;
    int microphone_count = 0;
    double microphone_position = 0.0;

    // Destroyed first, since its destructor still runs callbacks.
    std::unique_ptr<pipecat::PipecatClient> client;
    std::thread connector;
    std::thread reader;
};

//
// PipecatFunctionCall
//

void PipecatFunctionCall::respond(const Variant& result) {
    if (send_result) {
        send_result(result);
    }
}

void PipecatFunctionCall::_bind_methods() {
    ClassDB::bind_method(
            D_METHOD("get_function_name"),
            &PipecatFunctionCall::get_function_name
    );
    ClassDB::bind_method(
            D_METHOD("get_arguments"), &PipecatFunctionCall::get_arguments
    );
    ClassDB::bind_method(
            D_METHOD("respond", "result"),
            &PipecatFunctionCall::respond,
            DEFVAL(Variant())
    );

    ADD_PROPERTY(
            PropertyInfo(Variant::STRING, "function_name"),
            "",
            "get_function_name"
    );
    ADD_PROPERTY(
            PropertyInfo(Variant::DICTIONARY, "arguments"), "", "get_arguments"
    );
}

//
// PipecatClient
//

PipecatClient::PipecatClient() = default;

PipecatClient::~PipecatClient() = default;

void PipecatClient::_ready() {
    // Nodes from extensions also run in the editor.
    if (Engine::get_singleton()->is_editor_hint()) {
        set_process(false);
        return;
    }

    // The bot's voice.
    Ref<AudioStreamGenerator> stream;
    stream.instantiate();
    stream->set_mix_rate(AudioServer::get_singleton()->get_mix_rate());
    stream->set_buffer_length(BOT_VOICE_BUFFER_LENGTH);
    voice = memnew(AudioStreamPlayer);
    voice->set_stream(stream);
    add_child(voice, false, INTERNAL_MODE_FRONT);
    voice->play();
    voice_playback = voice->get_stream_playback();

    if (connect_on_ready) {
        // Once the whole scene is ready, so scripts can change the properties
        // in their own _ready().
        call_deferred("connect_to_bot");
    }
}

void PipecatClient::_process(double) {
    if (microphone_capture.is_valid()) {
        PackedVector2Array frames = microphone_capture->get_buffer(
                microphone_capture->get_frames_available()
        );
        if (session) {
            session->send_microphone(frames);
        }
    }

    if (session) {
        // A signal handler can disconnect, which destroys the session, so the
        // events are taken first.
        for (auto& event: session->take_events()) {
            event(*this);
        }
    }
}

void PipecatClient::_exit_tree() {
    disconnect_from_bot();
}

void PipecatClient::connect_to_bot() {
    if (session || voice_playback.is_null()) {
        return;
    }
    uint32_t mix_rate = uint32_t(AudioServer::get_singleton()->get_mix_rate());
    session = std::make_unique<PipecatSession>(mix_rate, voice_playback);
    if (use_microphone) {
        start_microphone();
    }
    session->start(start_url, api_key);
}

void PipecatClient::disconnect_from_bot() {
    stop_microphone();
    session.reset();
}

bool PipecatClient::is_bot_ready() const {
    return session && session->is_ready();
}

void PipecatClient::send_text(const String& text) {
    if (session) {
        session->send_text(text);
    }
}

void PipecatClient::send_client_message(
        const String& type,
        const Variant& data
) {
    if (session) {
        session->send_client_message(type, data);
    }
}

float PipecatClient::get_bot_voice_level() const {
    return session ? session->get_bot_voice_level() : 0.0f;
}

float PipecatClient::get_microphone_level() const {
    return session && microphone ? session->get_microphone_level() : 0.0f;
}

void PipecatClient::start_microphone() {
    if (!bool(ProjectSettings::get_singleton()->get_setting(
                "audio/driver/enable_input"
        ))) {
        UtilityFunctions::push_warning(
                "Pipecat: to use the microphone, turn on Audio > Driver > "
                "Enable Input in the "
                "project settings."
        );
        return;
    }

    // Godot captures the microphone from a bus, which is muted so the user
    // doesn't hear themselves.
    AudioServer* audio = AudioServer::get_singleton();
    int bus = audio->get_bus_count();
    audio->add_bus(bus);
    audio->set_bus_name(bus, MICROPHONE_BUS);
    audio->set_bus_mute(bus, true);
    microphone_capture.instantiate();
    audio->add_bus_effect(bus, microphone_capture);

    Ref<AudioStreamMicrophone> stream;
    stream.instantiate();
    microphone = memnew(AudioStreamPlayer);
    microphone->set_stream(stream);
    microphone->set_bus(MICROPHONE_BUS);
    add_child(microphone, false, INTERNAL_MODE_FRONT);
    microphone->play();
}

void PipecatClient::stop_microphone() {
    if (!microphone) {
        return;
    }
    // Stopped before its bus is gone, so it doesn't play on another one.
    microphone->stop();
    microphone->queue_free();
    microphone = nullptr;
    microphone_capture.unref();

    AudioServer* audio = AudioServer::get_singleton();
    int bus = audio->get_bus_index(MICROPHONE_BUS);
    if (bus >= 0) {
        audio->remove_bus(bus);
    }
}

void PipecatClient::_bind_methods() {
    ClassDB::bind_method(
            D_METHOD("connect_to_bot"), &PipecatClient::connect_to_bot
    );
    ClassDB::bind_method(
            D_METHOD("disconnect_from_bot"), &PipecatClient::disconnect_from_bot
    );
    ClassDB::bind_method(
            D_METHOD("is_bot_ready"), &PipecatClient::is_bot_ready
    );
    ClassDB::bind_method(
            D_METHOD("send_text", "text"), &PipecatClient::send_text
    );
    ClassDB::bind_method(
            D_METHOD("send_client_message", "type", "data"),
            &PipecatClient::send_client_message,
            DEFVAL(Variant())
    );
    ClassDB::bind_method(
            D_METHOD("get_bot_voice_level"), &PipecatClient::get_bot_voice_level
    );
    ClassDB::bind_method(
            D_METHOD("get_microphone_level"),
            &PipecatClient::get_microphone_level
    );

    ClassDB::bind_method(
            D_METHOD("set_start_url", "url"), &PipecatClient::set_start_url
    );
    ClassDB::bind_method(
            D_METHOD("get_start_url"), &PipecatClient::get_start_url
    );
    ClassDB::bind_method(
            D_METHOD("set_api_key", "key"), &PipecatClient::set_api_key
    );
    ClassDB::bind_method(D_METHOD("get_api_key"), &PipecatClient::get_api_key);
    ClassDB::bind_method(
            D_METHOD("set_connect_on_ready", "enabled"),
            &PipecatClient::set_connect_on_ready
    );
    ClassDB::bind_method(
            D_METHOD("get_connect_on_ready"),
            &PipecatClient::get_connect_on_ready
    );
    ClassDB::bind_method(
            D_METHOD("set_use_microphone", "enabled"),
            &PipecatClient::set_use_microphone
    );
    ClassDB::bind_method(
            D_METHOD("get_use_microphone"), &PipecatClient::get_use_microphone
    );

    ADD_PROPERTY(
            PropertyInfo(Variant::STRING, "start_url"),
            "set_start_url",
            "get_start_url"
    );
    ADD_PROPERTY(
            PropertyInfo(Variant::STRING, "api_key", PROPERTY_HINT_PASSWORD),
            "set_api_key",
            "get_api_key"
    );
    ADD_PROPERTY(
            PropertyInfo(Variant::BOOL, "connect_on_ready"),
            "set_connect_on_ready",
            "get_connect_on_ready"
    );
    ADD_PROPERTY(
            PropertyInfo(Variant::BOOL, "use_microphone"),
            "set_use_microphone",
            "get_use_microphone"
    );

    ADD_SIGNAL(MethodInfo("bot_ready"));
    ADD_SIGNAL(MethodInfo("disconnected"));
    ADD_SIGNAL(MethodInfo("error", PropertyInfo(Variant::STRING, "message")));
    ADD_SIGNAL(MethodInfo("user_started_speaking"));
    ADD_SIGNAL(MethodInfo("user_stopped_speaking"));
    ADD_SIGNAL(MethodInfo(
            "user_transcript",
            PropertyInfo(Variant::STRING, "text"),
            PropertyInfo(Variant::BOOL, "final")
    ));
    ADD_SIGNAL(MethodInfo("bot_started_speaking"));
    ADD_SIGNAL(MethodInfo("bot_stopped_speaking"));
    ADD_SIGNAL(MethodInfo("bot_interrupted"));
    ADD_SIGNAL(MethodInfo("bot_output", PropertyInfo(Variant::STRING, "text")));
    ADD_SIGNAL(MethodInfo(
            "server_message",
            PropertyInfo(
                    Variant::NIL,
                    "data",
                    PROPERTY_HINT_NONE,
                    "",
                    PROPERTY_USAGE_NIL_IS_VARIANT
            )
    ));
    ADD_SIGNAL(MethodInfo(
            "function_call",
            PropertyInfo(
                    Variant::OBJECT,
                    "function_call",
                    PROPERTY_HINT_RESOURCE_TYPE,
                    "PipecatFunctionCall"
            )
    ));
}
