The four-second H.264 test-pattern fixture is generated, contains no third-party footage, and has no audio.

Regenerate with:

```sh
ffmpeg -f lavfi -i testsrc2=size=160x90:rate=24 -t 4 -c:v libx264 -pix_fmt yuv420p -profile:v main -g 24 -keyint_min 24 -bf 0 -sc_threshold 0 -an -movflags +dash+global_sidx -f mp4 playback-video.m4s
```

The fixture has initialization bytes 0–776, SIDX bytes 777–864, and four one-second media fragments. If regeneration changes these offsets, update the test's track metadata too.

The companion audio fixture is a generated 440 Hz AAC tone:

```sh
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000 -t 4 -c:a aac -b:a 96k -vn -movflags +dash+global_sidx -f mp4 playback-audio.m4s
```

Audio initialization bytes are 0–732, SIDX bytes 733–784, and media starts at 785. AAC padding makes its presentation duration 4.021333 seconds.
