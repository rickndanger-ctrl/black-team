# Model connections

Black Team accepts model choices from the user. It loads GGUF with an owned
llama.cpp runtime, or connects to an existing local OpenAI-compatible server.
A model's architecture, file format, quantization and hardware requirements are
handled by the inference engine. Black Team cannot directly load every weight
format and does not convert or download models automatically.

## GGUF / llama.cpp

1. Obtain a model you have permission to use and a compatible Linux llama.cpp
   release from [the upstream project](https://github.com/ggml-org/llama.cpp/releases).
2. Extract the entire runtime directory; keep `llama-server` with its libraries.
3. In the first Workspace setup, or **Settings → Models**, choose **Model file**.
   Black Team looks for an installed llama.cpp runtime. Use **Choose model** for
   the GGUF and **Choose runtime** if a runtime was not found. Keep its libraries.
4. Choose **Save and open chat**, then send a message to start the model. The
   display name comes from the filename. Optional workspace, context, CPU threads
   and GPU layers are under **Advanced connection and performance**. Start with
   GPU layers at 0 for CPU operation. Memory notes are estimates, not guarantees.

The app verifies the GGUF header, native executable architecture, runtime model
identity and authentication. The runtime binds to a dynamically chosen loopback
port with a per-launch key stored in a temporary private file. Only Black Team's
owned process is managed. The runtime must expose authenticated `/props`,
`/apply-template` and `/tokenize` for exact chat context measurement.

A model startup failure can indicate unsupported architecture, missing shared
libraries, insufficient RAM/VRAM, or incompatible runtime endpoints. The alpha's
runtime startup deadline is two minutes. Large or slow models may need a
separately started server instead.

## Existing servers

1. Start your inference server and load/download your model in that application.
2. Enable its OpenAI-compatible API on this computer. In **Settings → Models**
   (or the first Workspace setup), choose **Ollama** or **LM Studio**. These buttons
   fill in the usual local address and immediately look for models. For another
   server, choose **Another server**, enter its HTTP `/v1` address, then **Find models**.
3. Select a model from the list and choose **Save and open chat**. Send a message
   to connect automatically. Use **Find models** again if you start the server later.
4. Only when needed, open **Advanced connection and performance** to change the
   address, add an API key, set an exact model ID manually, or adjust the context
   and workspace. Keys stay in private local configuration and are omitted from
   desktop/phone status responses.

Discovery checks `/v1/models`; generation uses streaming `/v1/chat/completions`.
A successful model list is not an inference test. The **Get Ollama** and **Get LM
Studio** links open their download pages; Black Team does not install them itself.

Preset URLs are `http://127.0.0.1:11434/v1` for Ollama and
`http://127.0.0.1:1234/v1` for LM Studio. Use the actual port selected in your server.
`localhost` is normalized to `127.0.0.1`; IPv6 loopback `[::1]` is accepted.
LAN/public addresses, URL credentials, query strings and redirects are rejected.
Changing the endpoint clears the saved server key unless you explicitly enter a
new key. Disconnecting never kills an independently managed server.

Choose a downloaded **local** model. A localhost endpoint can still forward to a
cloud provider; Black Team does not control that program's routing. The application
sends the exact selected model ID, so architecture names are not hardcoded.
Only plain-text chat is implemented. Agent work additionally needs compatible
tool calling. An embedding-only model can appear in a server's list without being
a usable chat model.

References: [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility),
[LM Studio model discovery](https://lmstudio.ai/docs/developer/openai-compat/models).

## Context windows

In owned GGUF Chat mode, Black Team renders the local chat template and counts
its real tokens. It reserves reply space, omits older complete turns when needed,
and preserves the saved conversation. It rejects an oversized current request
rather than silently shortening it.

Compatible APIs do not expose a universal tokenizer. Server Chat mode uses a
conservative UTF-8 byte estimate plus per-message overhead, visibly labeled as
**estimated**. It preserves system instructions/current input and removes only
older complete turns. This is not a guarantee for every tokenizer or chat template.
Set the context size no higher than your server's loaded context, and review its
own truncation settings. Black Team does not change that server's context settings.

Agent mode delegates context to Hermes, with the selected local endpoint used
for compaction and no configured cloud fallback. Tools/system prompts consume
context too: use a model and context size appropriate for agent work.

## Switching and sharing

Stop active work before changing connections. Choose **Change model** in
Workspace, then **Change model** in the connected-model card to disconnect and
unlock the setup form. Save the new selection and send a message to connect it. Multiple external harnesses can
share your server, but Black Team does not supervise their independent jobs or
measure their individual resource consumption. Closing Black Team stops its
owned GGUF runtime, which also affects external harnesses connected to it.
For independent harness lifetimes, use an independently managed local server.
