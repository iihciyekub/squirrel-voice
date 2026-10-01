# Third-party notices

Squirrel Voice is a modified distribution of Rime Squirrel and is distributed
under the GNU General Public License version 3. The upstream Squirrel source is
available at <https://github.com/rime/squirrel>.

The native ASR runtime links against `llama.cpp`, which is fetched at build time
and is distributed by its upstream project under the MIT License:
<https://github.com/ggml-org/llama.cpp>.

The R2T2 integration path is adapted from NetEase Youdao's
`Confucius4-R2T2/r2t2_llama/native_ext.cpp`. The upstream code carries its own
license terms. Model weights are **not** redistributed by Squirrel Voice; users
choose local model files separately. The default recommended model is:
<https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF>.

Squirrel and its build include additional third-party libraries such as
librime, Sparkle, OpenCC, and their dependencies. Their original notices and
license terms remain available from the respective upstream projects and the
corresponding Squirrel source tree used to build each release.
