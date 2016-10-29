" ============================================================================
" FILE: mplayer.vim
" AUTHOR: koturn <jeak.koutan.apple@gmail.com>
" DESCRIPTION: {{{
" A mplayer frontend for Vim.
" }}}
" ============================================================================
let s:save_cpo = &cpo
set cpo&vim


if has('win32unix')
  let g:mplayer#use_win_mplayer_in_cygwin = get(g:, 'mplayer#use_win_mplayer_in_cygwin', 0)
  let g:mplayer#cygwin_mount_dir = get(g:, 'mplayer#cygwin_mount_dir', '/cygdrive')
endif

let g:mplayer#mplayer = get(g:, 'mplayer#mplayer', 'mplayer')
if has('win32') || has('win32unix') && g:mplayer#use_win_mplayer_in_cygwin
  let g:mplayer#option = get(g:, 'mplayer#option',
        \ '-nofontconfig -idle -quiet -slave -af equalizer=0:0:0:0:0:0:0:0:0:0 -vo direct3d')
else
  let g:mplayer#option = get(g:, 'mplayer#option',
        \ '-nofontconfig -idle -quiet -slave -af equalizer=0:0:0:0:0:0:0:0:0:0')
endif
let g:mplayer#suffixes = get(g:, 'mplayer#suffixes', ['*'])
let g:mplayer#_use_job = get(g:, 'mplayer#_use_job', has('job') || has('nvim'))
let g:mplayer#_use_timer = get(g:, 'mplayer#_use_timer', has('timers'))

let g:mplayer#enable_ctrlp_multi_select = get(g:, 'mplayer#enable_ctrlp_multi_select', 1)

let s:V = vital#mplayer#new()
let s:List = s:V.import('Data.List')
let s:PM = s:V.import('ProcessManager')

let s:WAIT_TIME = g:mplayer#_use_job ? 50 : 0.05 | lockvar s:WAIT_TIME
if has('win32unix') && g:mplayer#use_win_mplayer_in_cygwin
  let s:TENC = 'cp932'
else
  let s:TENC = &termencoding
endif
lockvar s:TENC
if has('win32') || has('win32unix') && g:mplayer#use_win_mplayer_in_cygwin
  let s:LINE_BREAK = "\r\n"
else
  let s:LINE_BREAK = "\n"
endif
lockvar s:LINE_BREAK

let s:DUMMY_COMMAND = 'get_property __NONE__'
lockvar s:DUMMY_COMMAND
let s:DUMMY_PATTERN = '.*ANS_ERROR=PROPERTY_UNKNOWN' . s:LINE_BREAK
lockvar s:DUMMY_PATTERN

let s:INFO_COMMANDS = [
      \ 'get_time_pos', 'get_time_length', 'get_percent_pos', 'get_file_name',
      \ 'get_meta_title', 'get_meta_artist', 'get_meta_album', 'get_meta_year',
      \ 'get_meta_comment', 'get_meta_track', 'get_meta_genre',
      \ 'get_audio_codec', 'get_audio_bitrate', 'get_audio_samples',
      \ 'get_video_codec', 'get_video_bitrate', 'get_video_resolution'
      \]
lockvar s:INFO_COMMANDS

let s:eq_presets = mplayer#complete#_import_local_var('eq_presets')
let s:SUB_ARG_DICT = mplayer#complete#_import_local_var('SUB_ARG_DICT')
let s:HELP_DICT = mplayer#complete#_import_local_var('HELP_DICT')


let s:MPlayer = {
      \ 'mplayer': g:mplayer#mplayer,
      \ 'option': g:mplayer#option,
      \}
let s:instance_id = 0
let s:mplayer_list = []


function! mplayer#new() abort
  let mplayer = deepcopy(s:MPlayer)
  let mplayer.id = s:instance_id
  let s:instance_id += 1
  call add(s:mplayer_list, mplayer)

  let group = 'MPlayer' . mplayer.id
  execute 'augroup' group
  execute '  autocmd!'
  execute '  autocmd' group 'VimLeave * call s:mplayer_list[' . mplayer.id . '].stop()'
  execute 'augroup END'
  return mplayer
endfunction

function! mplayer#_import_local_var(name) abort
  return s:[a:name]
endfunction


if g:mplayer#_use_job
  if has('job')
    function! s:MPlayer.start(custom_option) abort
      if !executable(self.mplayer)
        echoerr 'Error: Please install mplayer.'
        return
      endif
      call self.stop()
      let self.handle = job_start(join([self.mplayer, self.option, a:custom_option]), {
            \ 'out_mode': 'raw'
            \})
      call self._read()
    endfunction

    function! s:MPlayer.is_playing() abort
      return has_key(self, 'handle') && job_status(self.handle) ==# 'run'
    endfunction

    function! s:MPlayer._read(...) abort
      let wait_time = a:0 > 0 ? a:1 : s:WAIT_TIME
      let pattern = a:0 > 1 ? a:2 : []
      let raw_text = ch_readraw(self.handle, {'timeout': wait_time})
      return substitute(raw_text, s:DUMMY_PATTERN, '', 'g')
    endfunction

    function! s:MPlayer._write(text) abort
      call ch_sendraw(self.handle, a:text)
    endfunction

    function! s:MPlayer.flush() abort
      if !self.is_playing() | return | endif
      return [ch_readraw(self.handle, {'timeout': 0}), ch_readraw(self.handle, {'part': 'err', 'timeout': 0})]
    endfunction
  elseif has('nvim')
    function! s:on_stdout(id, data, e) abort dict
      let self.stdout .= join(a:data, "\n")
    endfunction

    function! s:on_stderr(id, data, e) abort dict
      let self.stderr .= join(a:data, "\n")
    endfunction

    function! s:MPlayer.start(custom_option) abort
      if !executable(self.mplayer)
        echoerr 'Error: Please install mplayer.'
        return
      endif
      call self.stop()
      let self.jobopt = {
            \ 'stdout': '',
            \ 'stderr': '',
            \ 'on_stdout': function('s:on_stdout'),
            \ 'on_stderr': function('s:on_stderr')
            \}
      let self.handle = jobstart(join([self.mplayer, self.option, a:custom_option]), self.jobopt)
      call self._read()
    endfunction

    function! s:MPlayer.is_playing() abort
      try
        call jobpid(self.handle)
        return 1
      catch
        return 0
      endtry
    endfunction

    function! s:MPlayer._read(...) abort
      let wait_time = a:0 > 0 ? a:1 : s:WAIT_TIME
      execute 'sleep' wait_time . 'm'
      let raw_text = self.jobopt.stdout
      let self.jobopt.stdout = ''
      return substitute(raw_text, s:DUMMY_PATTERN, '', 'g')
    endfunction

    function! s:MPlayer._write(text) abort
      call jobsend(self.handle, a:text)
    endfunction

    function! s:MPlayer.flush() abort
      if !self.is_playing() | return | endif
      let r = [self.jobopt.stdout, self.jobopt.stderr]
      let [self.jobopt.stdout, self.jobopt.stderr] = ['', '']
      return r
    endfunction
  else
    echoerr 'Unexpected environment'
  endif
else
  function! s:MPlayer.start(custom_option) abort
    if !executable(self.mplayer)
      echoerr 'Error: Please install mplayer.'
      return
    endif
    if !s:PM.is_available()
      echoerr 'Error: vimproc is unavailable.'
      return
    endif
    call self.stop()
    let self.handle = 'mplayer-' . self.id
    call s:PM.touch(self.handle, join([self.mplayer, self.option, a:custom_option]))
    call self._read()
  endfunction

  function! s:MPlayer.is_playing() abort
    try
      let status = s:PM.status(self.handle)
      return status ==# 'inactive' || status ==# 'active'
    catch
      return 0
    endtry
  endfunction

  function! s:MPlayer._read(...) abort
    let wait_time = a:0 > 0 ? a:1 : s:WAIT_TIME
    let pattern = a:0 > 1 ? a:2 : []
    let raw_text = s:PM.read_wait(self.handle, wait_time, [])[0]
    return substitute(raw_text, s:DUMMY_PATTERN, '', 'g')
  endfunction

  function! s:MPlayer._write(text) abort
    call s:PM.write(self.handle, a:text)
  endfunction

  function! s:MPlayer.flush() abort
    if !self.is_playing() | return | endif
    return s:PM.read(self.handle, [])
  endfunction
endif


function! s:MPlayer.play(...) abort
  let pos = match(a:000, '^--$')
  if pos == -1
    let pos = a:0
  endif
  let custom_option = join(a:000[pos + 1 :], ' ')
  call self.start(custom_option)
  let filelist = a:000[: pos - 1]
  call self.enqueue(filelist)
endfunction

function! s:MPlayer.enqueue(...) abort
  if !self.is_playing()
    call self.start('')
  endif
  call self._write(join(extend(s:make_loadcmds(s:List.flatten(a:000)), [s:DUMMY_COMMAND, '']), "\n"))
  call self._read(s:WAIT_TIME)
endfunction

function! s:MPlayer.stop() abort
  if !self.is_playing() | return | endif
  call self._write("quit\n")
endfunction

function! s:MPlayer.get_file_info() abort
  if !self.is_playing() | return | endif
  call self._write(s:DUMMY_COMMAND . "\n")
  call self._write(join(s:INFO_COMMANDS, "\n") . "\n")
  return s:get_file_info(substitute(iconv(self._read(), s:TENC, &enc), "'", '', 'g'))
endfunction

function! s:MPlayer._command(cmd) abort
  if !self.is_playing() | return | endif
  call self._write(join([s:DUMMY_COMMAND, a:cmd, ''], "\n"))
  return self._read()
endfunction

function! s:MPlayer.command(cmd, ...) abort
  let is_iconv = a:0 > 0 ? a:1 : 0
  let str = self._command(a:cmd)
  if is_iconv
    let str = iconv(str, s:TENC, &enc)
  endif
  return matchstr(substitute(str, "^\e[A\r\e[K", '', ''), '^ANS_.\+=\zs.*$')
endfunction

function! s:MPlayer.next(...) abort
  let n = a:0 > 0 ? a:1 : 1
  return iconv(self._command('pt_step ' . n), s:TENC, &enc)
endfunction

function! s:MPlayer.prev(...) abort
  let n = -(a:0 > 0 ? a:1 : 1)
  return iconv(self._command('pt_step ' . n), s:TENC, &enc)
endfunction

function! s:MPlayer.set_loop(n) abort
  call self._write('loop ' . a:n . " 1\n")
endfunction

function! s:MPlayer.set_volume(level) abort
  call self._write('volume ' . a:level . " 1\n")
endfunction

function! s:MPlayer.set_seek(pos) abort
  let second = s:to_second(a:pos)
  let lastchar = a:pos[-1 :]
  return second != -1 ? self._command('seek ' . second . ' 2')
        \ : lastchar ==# 's' || lastchar =~# '\d' ? self._command('seek ' . a:pos . ' 2')
        \ : lastchar ==# '%' ? self._command('seek ' . a:pos . ' 1')
        \ : ''
endfunction

function! s:MPlayer.set_seek_to_head() abort
  call self._write("seek 0 1\n")
endfunction

function! s:MPlayer.set_seek_to_end() abort
  call self._write("seek 100 1\n")
endfunction

function! s:MPlayer.set_speed(speed, is_scaletempo) abort
  return [
        \ a:is_scaletempo ? self._command('af_add scaletempo') : self._command('af_del scaletempo'),
        \ self._command('speed_set ' . a:speed)
        \]
endfunction

function! s:MPlayer.set_equalizer(band_str) abort
  call self._command('af_eq_set_bands ' . get(s:eq_presets, a:band_str, a:band_str))
endfunction

function! s:MPlayer.toggle_mute() abort
  call self._write("mute\n")
endfunction

function! s:MPlayer.toggle_pause() abort
  call self._write("pause\n")
endfunction


function! s:make_loadcmds(args) abort
  let loadcmds = []
  for arg in a:args
    for item in split(expand(arg, 1), "\n")
      if isdirectory(item)
        let glob_pattern = empty(g:mplayer#suffixes) ? '*' : ('*.{' . join(g:mplayer#suffixes, ',') . '}')
        let dir_items = split(globpath(item, glob_pattern, 1), "\n")
        call extend(loadcmds, map(filter(dir_items, 'filereadable(v:val)'), 's:process_file(v:val)'))
      elseif item =~# '^\%(cdda\|cddb\|dvd\|file\|ftp\|gopher\|tv\|vcd\|http\|https\)://'
        call add(loadcmds, 'loadfile ' . item . ' 1')
      else
        call add(loadcmds, s:process_file(expand(item, 1)))
      endif
    endfor
  endfor
  return has('win32unix') && g:mplayer#use_win_mplayer_in_cygwin
        \ ? map(loadcmds, 'substitute(v:val, g:mplayer#cygwin_mount_dir . "/\\(\\a\\)", "\\1:", "")')
        \ : loadcmds
endfunction

function! s:process_file(file) abort
  return (a:file =~# '\.\%(m3u\|m3u8\|pls\|wax\|wpl\|xspf\)$' ? 'loadlist ' : 'loadfile ') . string(a:file) . ' 1'
endfunction

function! s:get_file_info(text) abort
  let answers = map(split(a:text, s:LINE_BREAK), 'matchstr(v:val, "^ANS_.\\+=\\zs.*$")')
  return len(answers) < 17 ? {} : {
        \ 'time_pos': answers[0],
        \ 'time_length': answers[1],
        \ 'percent_pos': answers[2],
        \ 'filename': answers[3],
        \ 'meta': {
        \   'title': answers[4],
        \   'artist': answers[5],
        \   'album': answers[6],
        \   'year': answers[7],
        \   'comment': answers[8],
        \   'track': answers[9],
        \   'genre': answers[10]
        \ },
        \ 'audio': {
        \   'codec': answers[11],
        \   'bitrate': answers[12],
        \   'sample': answers[13]
        \ },
        \ 'video': {
        \   'codec': answers[14],
        \   'bitrate': answers[15],
        \   'resolution': answers[16]
        \ }
        \}
endfunction

function! s:to_second(timestr) abort
  if a:timestr =~# '^\d\+:\d\+:\d\+\%(\.\d\+\)\?$'
    let parts = split(a:timestr, ':')
    return str2nr(parts[0]) * 3600 + str2nr(parts[1]) * 60 + str2nr(parts[2])
  elseif a:timestr =~# '^\d\+:\d\+\%(\.\d\+\)\?$'
    let parts = split(a:timestr, ':')
    return str2nr(parts[0]) * 60 + str2nr(parts[1])
  else
    return -1
  endif
endfunction


let &cpo = s:save_cpo
unlet s:save_cpo
