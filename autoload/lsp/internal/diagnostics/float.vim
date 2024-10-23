" internal state for whether it is enabled or not to avoid multiple subscriptions
let s:enabled = 0

let s:Markdown = vital#lsp#import('VS.Vim.Syntax.Markdown')
let s:MarkupContent = vital#lsp#import('VS.LSP.MarkupContent')
let s:FloatingWindow = vital#lsp#import('VS.Vim.Window.FloatingWindow')
let s:Window = vital#lsp#import('VS.Vim.Window')
let s:Buffer = vital#lsp#import('VS.Vim.Buffer')

function! lsp#internal#diagnostics#float#_enable() abort
    " don't even bother registering if the feature is disabled
    if !lsp#ui#vim#output#float_supported() | return | endif
    if !g:lsp_diagnostics_float_cursor | return | endif 

    if s:enabled | return | endif
    let s:enabled = 1

    " CursorMoved - Movement in normal or insert mode is expected to hide the
    " float and, potentially, show it later after a delay of
    " 'g:lsp_diagnostics_float_delay'.  So we always call 'hide_float()' for
    " this event, and may call 'show_float()' later.
    let s:Dispose_CursorMoved = lsp#callbag#pipe(
        \ lsp#callbag#fromEvent(['CursorMoved', 'CursorMovedI']),
        \ s:create_cursor_activity_filter(),
        \ lsp#callbag#tap({_->s:hide_float()}),
        \ s:subscribe_show_float_delayed(),
        \ )

    " CursorHold - If the cursor did not move long enough in the normal mode, we
    " want to hide the float.
    let s:Dispose_CursorHold = lsp#callbag#pipe(
        \ lsp#callbag#fromEvent(['CursorHold', 'CursorHoldI']),
        \ lsp#callbag#filter({_->g:lsp_diagnostics_float_hide_on_cursor_hold}),
        \ lsp#callbag#subscribe({_->s:hide_float()}),
        \ )

    " InsertEnter - If insert mode is entered and we do not show floats in the
    " insert mode (g:lsp_diagnostics_float_insert_mode_enabled) we want to hide
    " the float.
    let s:Dispose_InsertEnter = lsp#callbag#pipe(
        \ lsp#callbag#fromEvent(['InsertEnter']),
        \ lsp#callbag#filter({_->!g:lsp_diagnostics_float_insert_mode_enabled}),
        \ lsp#callbag#subscribe({_->s:hide_float()}),
        \ )

    " InsertLeave - If insert mode is disabled, we may want to show the float
    " after the insert mode is exited.  |CursorMoved| will not be triggered if
    " the cursor didn't move.
    let s:Dispose_InsertLeave = lsp#callbag#pipe(
        \ lsp#callbag#fromEvent(['InsertLeave']),
        \ lsp#callbag#filter({_->!g:lsp_diagnostics_float_insert_mode_enabled}),
        \ s:create_cursor_activity_filter(),
        \ s:subscribe_show_float_delayed(),
        \ )
endfunction

function! lsp#internal#diagnostics#float#_disable() abort
    if !s:enabled | return | endif
    if exists('s:Dispose_CursorMoved')
        call s:Dispose_CursorMoved()
        unlet s:Dispose_CursorMoved
    endif
    if exists('s:Dispose_CursorHold')
        call s:Dispose_CursorHold()
        unlet s:Dispose_CursorHold
    endif
    if exists('s:Dispose_InsertEnter')
        call s:Dispose_InsertEnter()
        unlet s:Dispose_InsertEnter
    endif
    if exists('s:Dispose_InsertLeave')
        call s:Dispose_InsertLeave()
        unlet s:Dispose_InsertLeave
    endif
    let s:enabled = 0
endfunction

" Constructs an operator that filters out events that trigger multiple times for
" the same combination of [buffer number, cursor position, b:changedtick]
"
" Produces output that holds an object like this:
" {
"     'bufnr': bufnr('%'),
"     'curpos': getcurpos()[0:2],
"     'changedtick': b:changedtick
" }
function! s:create_cursor_activity_filter() abort
    let l:Operator = {s->lsp#callbag#pipe(
        \ s,
        \ lsp#callbag#map({_->{
        \   'bufnr': bufnr('%'),
        \   'curpos': getcurpos()[0:2],
        \   'changedtick': b:changedtick
        \ }}),
        \ lsp#callbag#distinctUntilChanged({a,b ->
        \      a['bufnr'] == b['bufnr']
        \   && a['curpos'] == b['curpos']
        \   && a['changedtick'] == b['changedtick']
        \ }),
        \)}

    return l:Operator
endfunction

" Constructs a callbag subscription that will show the diagnostics float after
" the configured delay, but only if it still needs to be shown.
function! s:subscribe_show_float_delayed() abort
    let l:Callbag = {s->lsp#callbag#pipe(
        \ s,
        \ lsp#callbag#filter({_->g:lsp_diagnostics_float_cursor}),
        \ lsp#callbag#filter({_->getbufvar(bufnr('%'), '&buftype') !=# 'terminal' }),
        \ lsp#callbag#debounceTime(g:lsp_diagnostics_float_delay),
        \ lsp#callbag#filter({_->
        \      mode() is# 'n'
        \   || g:lsp_diagnostics_float_insert_mode_enabled && mode() is# 'i'
        \ }),
        \ lsp#callbag#distinctUntilChanged({a,b ->
        \      a['bufnr'] == b['bufnr']
        \   && a['curpos'] == b['curpos']
        \   && a['changedtick'] == b['changedtick']
        \ }),
        \ lsp#callbag#map({_->lsp#internal#diagnostics#under_cursor#get_diagnostic()}),
        \ lsp#callbag#subscribe({x->s:show_float(x)})
        \ )}

    return l:Callbag
endfunction

function! s:show_float(diagnostic) abort
    let l:doc_win = s:get_doc_win()
    if !empty(a:diagnostic) && has_key(a:diagnostic, 'message')
        " Update contents. 
        call deletebufline(l:doc_win.get_bufnr(), 1, '$')
        call setbufline(l:doc_win.get_bufnr(), 1, lsp#utils#_split_by_eol(a:diagnostic['message']))

        " Compute size. 
        if g:lsp_float_max_width >= 1
            let l:maxwidth = g:lsp_float_max_width
        elseif g:lsp_float_max_width == 0
            let l:maxwidth = &columns
        else
            let l:maxwidth = float2nr(&columns * 0.4)
        endif
        let l:size = l:doc_win.get_size({
        \   'maxwidth': l:maxwidth,
        \   'maxheight': float2nr(&lines * 0.4),
        \ })

        " Compute position.
        let l:pos = s:compute_position(l:size)

        " Open window. 
        call l:doc_win.open({
        \   'row': l:pos[0],
        \   'col': l:pos[1],
        \   'width': l:size.width,
        \   'height': l:size.height,
        \   'border': v:true,
        \   'topline': 1,
        \ })
    else
        call s:hide_float()
    endif
endfunction

function! s:hide_float() abort
    let l:doc_win = s:get_doc_win()
    call l:doc_win.close()
endfunction

function! s:get_doc_win() abort
    if exists('s:doc_win')
        return s:doc_win
    endif

    let s:doc_win = s:FloatingWindow.new({
    \   'on_opened': { -> execute('doautocmd <nomodeline> User lsp_float_opened') },
    \   'on_closed': { -> execute('doautocmd <nomodeline> User lsp_float_closed') }
    \ })
    call s:doc_win.set_var('&wrap', 1)
    call s:doc_win.set_var('&conceallevel', 2)
    noautocmd silent let l:bufnr = s:Buffer.create()
    call s:doc_win.set_bufnr(l:bufnr)
    call setbufvar(s:doc_win.get_bufnr(), '&buftype', 'nofile')
    call setbufvar(s:doc_win.get_bufnr(), '&bufhidden', 'hide')
    call setbufvar(s:doc_win.get_bufnr(), '&buflisted', 0)
    call setbufvar(s:doc_win.get_bufnr(), '&swapfile', 0)
    return s:doc_win
endfunction

function! s:compute_position(size) abort
    let l:pos = screenpos(0, line('.'), col('.'))
    if l:pos.row == 0 && l:pos.col == 0
        let l:pos = {'curscol': screencol(), 'row': screenrow()}
    endif
    let l:pos = [l:pos.row + 1, l:pos.curscol + 1]
    if l:pos[0] + a:size.height > &lines
        let l:pos[0] = l:pos[0] - a:size.height - 3
    endif
    if l:pos[1] + a:size.width > &columns
        let l:pos[1] = l:pos[1] - a:size.width - 3
    endif
    return l:pos
endfunction
