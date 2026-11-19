// The quits the session makes itself when its run ends (--quit-at-end): the tree's sounds stop first, and the quit
// waits until the AudioServer has freed their playbacks, so a sound playing on the last tick is not reported as leaked
// at exit. An app's own quit (a menu's Quit) is the app's.
package godot

import "core:time"
import gd "unified:gdext"
import "unified:gdext/gdi"

// How long a quit waits for the stopped sounds' playbacks to be freed before it quits anyway.
@(private)
QUIT_AUDIO_WAIT :: time.Second

// The playbacks a quit waits for; with more sounds than this at once it waits out QUIT_AUDIO_WAIT.
@(private)
QUIT_PLAYBACKS_MAX :: 64

// A quit the session asked for, waiting for the sounds it stopped.
@(private)
Quit_Wait :: struct {
	asked:     bool,
	sent:      bool, // SceneTree.quit was called (it happens at the end of that frame)
	exit_code: int,
	started:   time.Tick,
	playbacks: [QUIT_PLAYBACKS_MAX]u64, // instance ids of the stopped players' playbacks
	count:     int,
	overflow:  bool, // more than QUIT_PLAYBACKS_MAX: wait the whole QUIT_AUDIO_WAIT
}

// Quits with `exit_code` once every sound in the tree has stopped and the AudioServer has let go of it (at most
// QUIT_AUDIO_WAIT later). Until then session_process runs only quit_step. A second request keeps the first's code.
@(private)
quit_when_quiet :: proc(session: ^Session_Node, exit_code: int) {
	if session.quitting.asked do return
	session.quitting = {
		asked     = true,
		exit_code = exit_code,
		started   = time.tick_now(),
	}
	quit_step(session)
}

// One frame of a requested quit: stops what plays (a sound a script started since the last frame too), and quits once
// every stopped playback is freed or the wait is over. True while a quit is requested: the frame does nothing else.
@(private)
quit_step :: proc(session: ^Session_Node) -> bool {
	wait := &session.quitting
	if !wait.asked do return false
	if wait.sent do return true
	tree := gd.Node_get_tree(node_of(session))
	stop_sounds(gd.cast_to(gd.Node, gd.SceneTree_get_root(tree)), wait)
	quiet := !wait.overflow
	for id in wait.playbacks[:wait.count] {
		if gdi.object_get_instance_from_id(id) != nil do quiet = false
	}
	if quiet || time.tick_since(wait.started) >= QUIT_AUDIO_WAIT {
		gd.SceneTree_quit(tree, wait.exit_code)
		wait.sent = true
	}
	return true
}

// Stops every audio player under `root`, noting the playback of each one that had one.
@(private)
stop_sounds :: proc(root: gd.Node, wait: ^Quit_Wait) {
	for class in ([]string{"AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"}) {
		players := gd.Node_find_children(root, "*", class, true, false)
		defer gd.Array_destroy(&players)
		for i in 0 ..< gd.Array_size(&players) {
			item := gd.Array_get(&players, i)
			defer gd.variant_destroy(&item)
			player, _ := gd.from_variant(gd.Object, &item)
			if player.ptr == nil do continue
			has := gd.Object_call(player, "has_stream_playback")
			defer gd.variant_destroy(&has)
			if playing, _ := gd.from_variant(bool, &has); playing {
				playback_variant := gd.Object_call(player, "get_stream_playback")
				defer gd.variant_destroy(&playback_variant)
				playback, _ := gd.from_variant(gd.Object, &playback_variant)
				if playback.ptr != nil && wait.count < QUIT_PLAYBACKS_MAX {
					wait.playbacks[wait.count] = gdi.object_get_instance_id(playback.ptr)
					wait.count += 1
				} else if playback.ptr != nil {
					wait.overflow = true
				}
			}
			stopped := gd.Object_call(player, "stop")
			gd.variant_destroy(&stopped)
		}
	}
}
