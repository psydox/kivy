'''
SDL3 audio provider
===================

This core audio implementation require SDL_mixer library.
It might conflict with any other library that are using SDL_mixer, such as
ffmpeg-android.

Native formats:

* wav, since 1.9.0

Depending the compilation of SDL3 mixer and/or installed libraries:

* ogg since 1.9.1 (mixer needs libvorbis/libogg)
* flac since 1.9.1 (mixer needs libflac)
* mp3 since 1.9.1 (mixer needs libsmpeg/libmad; only use mad for GPL apps)
  * Since 1.10.1 + mixer 2.0.2, mpg123 can also be used
* sequenced formats since 1.9.1 (midi, mod, s3m, etc. Mixer needs
  libmodplug or libmikmod)

.. Note::

    Sequenced format support changed with mixer v2.0.2. If mixer is
    linked with one of libmodplug or libmikmod, format support for
    both libraries is assumed. This will work perfectly with formats
    supported by both libraries, but if you were to try to load an
    obscure format (like `apun` file with mikmod only), it will fail.

    * Kivy <= 1.10.0: will fail to build with mixer >= 2.0.2
      will report correct format support with < 2.0.2
    * Kivy >= 1.10.1: will build with old and new mixer, and
      will "guesstimate" sequenced format support

.. Warning::

    Sequenced formats use the SDL3 Mixer music channel, you can only play
    one at a time, and .length will be -1 if music fails to load, and 0
    if loaded successfully (we can't get duration of these formats)
'''

__all__ = ('SoundSDL3', 'MusicSDL3')

include "../../../kivy/lib/sdl3.pxi"

from kivy.core.audio_output import Sound, SoundLoader
from kivy.logger import Logger
from kivy.clock import Clock

cdef int mix_is_init = 0
cdef int mix_flags = 0


cdef mix_init():
    cdef SDL_AudioSpec desired_spec
    cdef int want_flags = 0
    global mix_is_init
    global mix_flags

    # avoid next call
    if mix_is_init != 0:
        return

    if SDL_Init(SDL_INIT_AUDIO) < 0:
        Logger.critical('AudioSDL3: Unable to initialize SDL: {}'.format(
                        SDL_GetError()))
        mix_is_init = -1
        return 0

    # In mixer 2.0.2, MIX_INIT_MODPLUG is now implied by MIX_INIT_MOD,
    # and MIX_INIT_FLUIDSYNTH was renamed to MIX_INIT_MID. In previous
    # versions, we requested both _MODPLUG and _MOD + _FLUIDSYNTH.
    # 0x20 used to be MIX_INIT_FLUIDSYNTH, now MIX_INIT_MID
    # 0x4  used to be MIX_INIT_MODPLUG before 2.0.2
    want_flags = MIX_INIT_FLAC | MIX_INIT_OGG | MIX_INIT_MP3
    want_flags |= MIX_INIT_MOD | 0x20 | 0x4

    mix_flags = Mix_Init(want_flags)

    desired_spec.freq = 44100
    desired_spec.format = SDL_AUDIO_S16
    desired_spec.channels = 2    
    if Mix_OpenAudio(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &desired_spec):
        Logger.critical('AudioSDL3: Unable to open mixer: {}'.format(
                        SDL_GetError()))
        mix_is_init = -1
        return 0

    mix_is_init = 1
    return 1

# Container for samples (Mix_LoadWAV)
cdef class ChunkContainer:
    cdef Mix_Chunk *chunk
    cdef Mix_Chunk *original_chunk
    cdef int channel

    def __init__(self):
        self.chunk = NULL
        self.channel = -1

    def __dealloc__(self):
        if self.chunk != NULL:
            if Mix_GetChunk(self.channel) == self.chunk:
                Mix_HaltChannel(self.channel)
            Mix_FreeChunk(self.chunk)
            self.chunk = NULL
        if self.original_chunk != NULL:
            Mix_FreeChunk(self.original_chunk)
            self.original_chunk = NULL

# Container for music (Mix_LoadMUS), one channel only
cdef class MusicContainer:
    cdef Mix_Music *music
    cdef int playing

    def __init__(self):
        self.music = NULL
        self.playing = 0

    def __dealloc__(self):
        if self.music != NULL:
            # I think FreeMusic halts automatically, probably not needed
            if Mix_PlayingMusic() and self.playing:
                Mix_HaltMusic()
            Mix_FreeMusic(self.music)
            self.music = NULL


class SoundSDL3(Sound):

    @staticmethod
    def extensions():
        mix_init()
        extensions = ["wav"]
        if mix_flags & MIX_INIT_FLAC:
            extensions.append("flac")
        if mix_flags & MIX_INIT_MP3:
            extensions.append("mp3")
        if mix_flags & MIX_INIT_OGG:
            extensions.append("ogg")
        return extensions

    def __init__(self, **kwargs):
        self._check_play_ev = None
        self.cc = ChunkContainer()
        mix_init()
        super(SoundSDL3, self).__init__(**kwargs)

    def _check_play(self, dt):
        cdef ChunkContainer cc = self.cc
        if cc.channel == -1 or cc.chunk == NULL:
            return False
        if Mix_Playing(cc.channel):
            return
        if self.loop:
            def do_loop(dt):
                self.play()
            Clock.schedule_once(do_loop)
        else:
            self.stop()
        return False

    def _get_length(self):
        cdef ChunkContainer cc = self.cc
        cdef int freq, channels
        cdef unsigned int points, frames
        cdef SDL_AudioFormat fmt
        if cc.chunk == NULL:
            return 0
        if not Mix_QuerySpec(&freq, &fmt, &channels):
            return 0
        points = <unsigned int>int(cc.chunk.alen / ((fmt & 0xFF) / 8))
        frames = <unsigned int>int(points / channels)
        return <double>frames / <double>freq

    def on_pitch(self, instance, value):
        cdef ChunkContainer cc = self.cc

        cdef Uint8 *dst_data = NULL;
        cdef int dst_len = 0;

        cdef SDL_AudioSpec src_spec
        cdef SDL_AudioSpec dst_spec

        if cc.chunk == NULL:
            return

        if not Mix_QuerySpec(&src_spec.freq, &src_spec.format, &src_spec.channels):
            return

        dst_spec.freq = int(src_spec.freq * value)
        dst_spec.format = src_spec.format
        dst_spec.channels = src_spec.channels

        if SDL_ConvertAudioSamples(&src_spec, cc.original_chunk.abuf, cc.original_chunk.alen, &dst_spec, &dst_data, &dst_len) < 0:
            Logger.warning("SoundSDL3: Error converting audio samples: %s" % SDL_GetError())
            return

        cc.chunk = Mix_QuickLoad_RAW(dst_data, dst_len)
        SDL_free(dst_data)

    def play(self):
        cdef ChunkContainer cc = self.cc
        self.stop()
        if cc.chunk == NULL:
            return
        cc.chunk.volume = int(self.volume * 128)
        cc.channel = Mix_PlayChannel(-1, cc.chunk, 0)
        if cc.channel == -1:
            Logger.warning('AudioSDL3: Unable to play {}: {}'.format(
                           self.source, SDL_GetError()))
            return
        # schedule event to check if the sound is still playing or not
        self._check_play_ev = Clock.schedule_interval(self._check_play, 0.1)
        super(SoundSDL3, self).play()

    def stop(self):
        cdef ChunkContainer cc = self.cc
        if cc.chunk == NULL or cc.channel == -1:
            return
        if Mix_GetChunk(cc.channel) == cc.chunk:
            Mix_HaltChannel(cc.channel)
        cc.channel = -1
        if self._check_play_ev is not None:
            self._check_play_ev.cancel()
            self._check_play_ev = None
        super(SoundSDL3, self).stop()

    def load(self):
        cdef ChunkContainer cc = self.cc
        self.unload()
        if self.source is None:
            return

        if isinstance(self.source, bytes):
            fn = self.source
        else:
            fn = self.source.encode('UTF-8')

        cc.chunk = Mix_LoadWAV(<char *><bytes>fn)
        if cc.chunk == NULL:
            Logger.warning('AudioSDL3: Unable to load {}: {}'.format(
                           self.source, SDL_GetError()))
        else:
            cc.original_chunk = Mix_QuickLoad_RAW(cc.chunk.abuf, cc.chunk.alen)
            cc.chunk.volume = int(self.volume * 128)
            if self.pitch != 1.:
                self.on_pitch(self, self.pitch)

    def unload(self):
        cdef ChunkContainer cc = self.cc
        self.stop()
        if cc.chunk != NULL:
            Mix_FreeChunk(cc.chunk)
            cc.chunk = NULL

    def on_volume(self, instance, volume):
        cdef ChunkContainer cc = self.cc
        if cc.chunk != NULL:
            cc.chunk.volume = int(volume * 128)


# LoadMUS supports OGG, MP3, WAV but we only use it for native midi,
# libmikmod, libmodplug and libfluidsynth to avoid confusion
class MusicSDL3(Sound):

    @staticmethod
    def extensions():
        mix_init()
        # FIXME: this should probably evolve to use the new has_music()
        #        interface to determine format support

        # Assume native midi support (defaults to enabled), but may use
        # modplug, fluidsynth or timidity in reality. It may also be
        # disabled completely, in which case loading it will fail
        extensions = set(['mid', 'midi'])

        # libmodplug and libmikmod, may be incomplete.
        # 0x4 is for mixer < 2.0.2, MIX_INIT_MODPLUG
        if mix_flags & (MIX_INIT_MOD | 0x4):
            extensions.update(['669', 'abc', 'amf', 'ams', 'apun', 'dbm',
                               'dmf', 'dsm', 'far', 'gdm', 'it',   'j2b',
                               'mdl', 'med', 'mod', 'mt2', 'mtm',  'okt',
                               'pat', 'psm', 'ptm', 's3m', 'stm',  'stx',
                               'ult', 'umx', 'uni', 'xm'])

        return list(extensions)

    def __init__(self, **kwargs):
        self.mc = MusicContainer()
        self._check_play_ev = None
        mix_init()
        super(MusicSDL3, self).__init__(**kwargs)

    def _check_play(self, dt):
        cdef MusicContainer mc = self.mc
        if mc.music == NULL:
            return False
        if mc.playing and Mix_PlayingMusic():
            return
        if self.loop:
            def do_loop(dt):
                self.play()
            Clock.schedule_once(do_loop)
        else:
            self.stop()
        return False

    # No way to check length; return -1 if music is loaded, 0 otherwise
    def _get_length(self):
        cdef MusicContainer mc = self.mc
        if mc.music == NULL:
            return -1
        return 0

    def play(self):
        cdef MusicContainer mc = self.mc
        self.stop()
        if mc.music == NULL:
            return
        Mix_VolumeMusic(int(self.volume * 128))
        if Mix_PlayMusic(mc.music, 1) == -1:
            Logger.warning('AudioSDL3: Unable to play music {}: {}'.format(
                           self.source, SDL_GetError()))
            return
        mc.playing = 1
        # schedule event to check if the sound is still playing or not
        self._check_play_ev = Clock.schedule_interval(self._check_play, 0.1)
        super(MusicSDL3, self).play()

    def stop(self):
        cdef MusicContainer mc = self.mc
        if mc.music == NULL or not mc.playing:
            return
        Mix_HaltMusic()
        mc.playing = 0
        if self._check_play_ev is not None:
            self._check_play_ev.cancel()
            self._check_play_ev = None
        super(MusicSDL3, self).stop()

    def load(self):
        cdef MusicContainer mc = self.mc
        self.unload()
        if self.source is None:
            return

        if isinstance(self.source, bytes):
            fn = self.source
        else:
            fn = self.source.encode('UTF-8')

        mc.music = Mix_LoadMUS(<char *><bytes>fn)
        if mc.music == NULL:
            Logger.warning('AudioSDL3: Unable to load music {}: {}'.format(
                           self.source, SDL_GetError()))
        else:
            Mix_VolumeMusic(int(self.volume * 128))

    def unload(self):
        cdef MusicContainer mc = self.mc
        self.stop()
        if mc.music != NULL:
            Mix_FreeMusic(mc.music)
            mc.music = NULL

    def on_volume(self, instance, volume):
        cdef MusicContainer mc = self.mc
        if mc.music != NULL and mc.playing:
            Mix_VolumeMusic(int(volume * 128))


SoundLoader.register(SoundSDL3)
SoundLoader.register(MusicSDL3)
