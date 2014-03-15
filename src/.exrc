if &cp | set nocp | endif
map  h
let s:cpo_save=&cpo
set cpo&vim
map <NL> j
map  k
map  l
map   /
vnoremap <silent> # :call VisualSearch('b')
vnoremap $e `>a"`<i"
vnoremap $q `>a'`<i'
vnoremap $$ `>a"`<i"
vnoremap $3 `>a}`<i{
vnoremap $2 `>a]`<i[
vnoremap $1 `>a)`<i(
vnoremap <silent> * :call VisualSearch('f')
map ,bb :cd ..
map ,pp :setlocal paste!
map ,q :e ~/buffer
noremap ,m mmHmt:%s///ge'tzt'm
noremap ,y :CommandTFlush
noremap ,j :CommandT
map ,f :MRU
map ,s? z=
map ,sa zg
map ,sp [s
map ,sn ]s
map ,ss :setlocal spell!
map ,u :TMiniBufExplorer
map ,o :BufExplorer
map ,p :cp
map ,n :cn
map ,cc :botright cope
map ,cd :cd %:p:h
map ,tm :tabmove
map ,tc :tabclose
map ,te :tabedit
map ,tn :tabnew
map ,ba :1,300 bd!
map ,bd :Bclose
map <silent> , :noh
map ,g :vimgrep // **/*.<Left><Left><Left><Left><Left><Left><Left>
map ,e :e! ~/.vim_runtime/vimrc
nmap ,w :w!
map 0 ^
cmap ½ $
imap ½ $
nmap gx <Plug>NetrwBrowseX
vnoremap <silent> gv :call VisualSearch('gv')
nnoremap <silent> <Plug>NetrwBrowseX :call netrw#NetrwBrowseX(expand("<cWORD>"),0)
nnoremap <SNR>3_I_won’t_ever_type_this <Plug>IMAP_JumpForward
map <Left> :bp
map <Right> :bn
map <C-Space> ?
cnoremap  <Home>
cnoremap  <End>
cnoremap  
cnoremap  <Down>
cnoremap  <Up>
inoremap $t <>i
inoremap $e ""i
inoremap $q ''i
inoremap $4 {o}O
inoremap $3 {}i
inoremap $2 []i
inoremap $1 ()i
cnoremap $q eDeleteTillSlash()
cnoremap $c e eCurrentFileDir("e")
cnoremap $j e ./
cnoremap $d e ~/Desktop/
cnoremap $h e ~/
vmap ½ $
nmap ½ $
omap ½ $
vmap ë :m'<-2`>my`<mzgv`yo`z
vmap ê :m'>+`<my`>mzgv`yo`z
nmap ë mz:m-2`z
nmap ê mz:m+`z
iabbr xdate =strftime("%d/%m/%y %H:%M:%S")
let &cpo=s:cpo_save
unlet s:cpo_save
set autoindent
set autoread
set backspace=eol,start,indent
set cmdheight=2
set expandtab
set fileencodings=ucs-bom,utf-8,default,latin1
set fileformats=unix,dos,mac
set grepprg=/bin/grep\ -nH
set guifont=Ubuntu\ Mono\ 12
set guitablabel=%t
set helplang=en
set hidden
set history=700
set hlsearch
set ignorecase
set incsearch
set laststatus=2
set matchtime=2
set nomodeline
set printoptions=paper:letter
set ruler
set runtimepath=~/.vim,/var/lib/vim/addons,/usr/share/vim/vimfiles,/usr/share/vim/vim73,/usr/share/vim/vimfiles/after,/var/lib/vim/addons/after,~/.vim/after
set scrolloff=7
set shiftwidth=2
set showmatch
set showtabline=2
set smartcase
set smartindent
set smarttab
set statusline=\ %{HasPaste()}%F%m%r%h\ %w\ \ CWD:\ %r%{CurDir()}%h\ \ \ Line:\ %l/%L:%c
set suffixes=.bak,~,.swp,.o,.info,.aux,.log,.dvi,.bbl,.blg,.brf,.cb,.ind,.idx,.ilg,.inx,.out,.toc
set noswapfile
set switchbuf=usetab
set tabstop=2
set tags=./tags,tags,../tags
set textwidth=500
set timeoutlen=500
set whichwrap=b,s,<,>,h,l
set wildignore=*.o,*.obj,.git,*.pyc
set wildmenu
set nowritebackup
" vim: set ft=vim :
