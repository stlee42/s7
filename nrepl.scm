;;; nrepl.scm -- notcurses-based repl
;;; 
;;; work-in-progress!

(set! (*s7* 'history-enabled) #f)

(provide 'nrepl.scm)
(require libc.scm)
(load "notcurses_s7.so" (inlet 'init_func 'notcurses_s7_init))

(define old-debug (*s7* 'debug))
(set! (*s7* 'debug) 0)
(define nrepl-debugging #f)

(autoload 'lint "lint.scm")
(autoload 'pretty-print "write.scm")
(autoload '*libm* "libm.scm")
(autoload '*libgsl* "libgsl.scm")
(autoload 'trace "debug.scm")
(autoload 'untrace "debug.scm")
(autoload 'break "debug.scm")
(autoload 'unbreak "debug.scm")
(autoload 'watch "debug.scm")
(autoload 'unwatch "debug.scm")
(autoload 'ow! "stuff.scm")

(unless (defined? '*nrepl*)
  (define *nrepl*
    (let* ((ncd #f)
	   (nc #f)
	   (nc-cols 0)
	   (nc-rows 0)
	   (top-level-let 
	    (sublet (rootlet) ; environment in which evaluation takes place

	      :history #f        ; set below
	      :nc-let #f
	      :display-status #f

	      :exit (let ((+documentation+ "(exit) stops notcurses and then calls #_exit"))
		      (let-temporarily (((*s7* 'debug) 0))
			(lambda ()
			  (notcurses_stop (*nrepl* 'nc))
			  (#_exit))))
	      
	      :time (macro (expr) 
		      `(let ((start (*s7* 'cpu-time)))
			 ,expr 
			 (- (*s7* 'cpu-time) start)))
	      
	      :apropos
	      (let ((levenshtein 
		     (lambda (s1 s2)
		       (let ((L1 (length s1))
			     (L2 (length s2)))
			 (cond ((zero? L1) L2)
			       ((zero? L2) L1)
			       (else (let ((distance (make-vector (list (+ L2 1) (+ L1 1)) 0)))
				       (do ((i 0 (+ i 1)))
					   ((> i L1))
					 (set! (distance 0 i) i))
				       (do ((i 0 (+ i 1)))
					   ((> i L2))
					 (set! (distance i 0) i))
				       (do ((i 1 (+ i 1)))
					   ((> i L2))
					 (do ((j 1 (+ j 1)))
					     ((> j L1))
					   (let ((c1 (+ (distance i (- j 1)) 1))
						 (c2 (+ (distance (- i 1) j) 1))
						 (c3 (if (char=? (s2 (- i 1)) (s1 (- j 1)))
							 (distance (- i 1) (- j 1))
							 (+ (distance (- i 1) (- j 1)) 1))))
					     (set! (distance i j) (min c1 c2 c3)))))
				       (distance L2 L1)))))))
		    
		    (make-full-let-iterator             ; walk the entire let chain
		     (lambda* (lt (stop (rootlet))) 
		       (if (eq? stop lt)
			   (make-iterator lt)
			   (letrec ((iterloop 
				     (let ((iter (make-iterator lt))
					   (+iterator+ #t))
				       (lambda ()
					 (let ((result (iter)))
					   (if (and (eof-object? result)
						    (iterator-at-end? iter)
						    (not (eq? stop (iterator-sequence iter))))
					       (begin 
						 (set! iter (make-iterator (outlet (iterator-sequence iter))))
						 (iterloop))
					       result))))))
			     (make-iterator iterloop))))))
		
		(lambda* (name (e (*nrepl* 'top-level-let)))
		  (let ((ap-name (if (string? name) name 
				     (if (symbol? name) 
					 (symbol->string name)
					 (error 'wrong-type-arg "apropos argument 1 should be a string or a symbol"))))
			(ap-env (if (let? e) e 
				    (error 'wrong-type-arg "apropos argument 2 should be an environment"))))
		    (let ((strs ())
			  (min2 (floor (log (length ap-name) 2)))
			  (have-orange (string=? ((*libc* 'getenv) "TERM") "xterm-256color")))
		      (for-each
		       (lambda (binding)
			 (if (pair? binding)
			     (let ((symbol-name (symbol->string (car binding))))
			       (if (string-position ap-name symbol-name)
				   (set! strs (cons (cons binding 0) strs))
				   (let ((distance (levenshtein ap-name symbol-name)))
				     (if (< distance min2)
					 (set! strs (cons (cons binding distance) strs))))))))
		       (make-full-let-iterator ap-env))
		      
		      (if (not (pair? strs))
			  'no-match
			  (let ((data "")
				(name-len (length name)))
			    (for-each (lambda (b)
					(set! data (string-append data 
								  (if (> (length data) 0) (string #\newline) "")
								  (if (procedure? (cdar b))
								      (let ((doc (documentation (cdar b)))) ; returns "" if no doc
									(if (positive? (length doc))
									    doc
									    (object->string (caar b))))
								      (object->string (caar b))))))
				      (sort! strs (lambda (a b)
						    (or (< (cdr a) (cdr b))
							(and (= (cdr a) (cdr b))
							     (< (abs (- (length (symbol->string (caar a))) name-len))
								(abs (- (length (symbol->string (caar b))) name-len))))))))
			    data))))))
	      )))
      
      ;; to call notcurses functions in the repl, use *nrepl*:  (notcurses_refresh (*nrepl* 'nc))
      
      ;; -------- completion --------
      (define (symbol-completion text)
	(let ((st (symbol-table))
	      (text-len (length text))
	      (match #f))
	  (call-with-exit
	   (lambda (return)
	     (for-each
	      (lambda (par)
		(let* ((sym (symbol->string par))
		       (sym-len (length sym)))
		  (when (and (>= sym-len text-len)
			     (string=? text (substring sym 0 text-len)))
		    (if match
			;; more than one match, save the longest text that all syms match
			(do ((min-len (min (string-length match) sym-len))
			     (i text-len (+ i 1)))
			    ((or (= i min-len)
				 (not (char=? (match i) (sym i))))
			     (if (= min-len text-len)
				 (return text)
				 (set! match (substring match 0 i)))))
			(set! match sym)))))
	      st)
	     ;(or match text)
	     match
	     ))))
      
      (define (filename-completion text)
	(and (> (length text) 0)
	     (with-let (sublet *libc* :text text)
	       (let ((g (glob.make)))
		 (glob (string-append text "*")
		       (logior (if (and (defined? 'GLOB_TILDE)
					(char=? (text 0) #\~))
				   GLOB_TILDE
				   0)
			       GLOB_MARK)
		       g)
		 (let ((files (map (lambda (f) ; get rid of emacs' *~ files
				     (if (and (> (length f) 1)
					      (char=? #\~ (f (- (length f) 1))))
					 (values)
					 f))
				   (glob.gl_pathv g))))
		   (globfree g) 
		   (if (or (null? files)
			   (not (null? (cdr files))))
		       #f ;text
		       (car files)))))))

      (define (move-cursor ncd y x)   ; this was (format *stderr* "~C[~D;~DH" #\escape y x) in repl.scm (and it works here)
	(ncdirect_cursor_move_yx ncd y x))
      
      (define* (run orig-col orig-row)     ; TODO: need prompt arg
	;; ncp-cols and rows, origs
	(let ((ncp-nc-col (or orig-col 0)) ; ncp top-left in nc (possibly started offset from nc 0,0)
	      (ncp-nc-row (or orig-row 0))
	      (ncp-col 0)                  ; top-left in ncp (possibly scrolled from original 0,0)
	      (ncp-row 0)
	      (ncp-cols (max 100 nc-cols))
	      (ncp-rows (max 100 nc-rows))
	      (ncp-max-row 0)
	      (col 0)
	      (row 0)
	      (prompt ">")
	      (prompt-len 2)
	      (unbound-case #f)
	      (prev-pars #f)
	      (old-history (top-level-let 'history))) ; see below, old restored upon exit from this ncplane
	  (set! (setter 'col) integer?)
	  (set! (setter 'row) integer?)
	  
	  (let ((ncp (ncplane_new nc ncp-rows ncp-cols ncp-nc-row ncp-nc-col (c-pointer 0)))
		(eols (make-int-vector ncp-rows 0))
		(bols (make-int-vector ncp-rows 0)))
	    
	    (define (nc-display r c str)
	      (ncplane_putstr_yx ncp r c (make-string 80 #\space))
	      (ncplane_putstr_yx ncp r c str)
	      (notcurses_render nc))
      
	    (set! (top-level-let 'nc-let) (curlet))

	    (set! (top-level-let 'history)
		  (lambda (filename)
		    (call-with-output-file filename
		      (lambda (p)
			(let ((timestamp (with-let (sublet *libc*)
					   (let ((timestr (make-string 128))) 
					     (let ((len (strftime timestr 128 "%a %d-%b-%Y %H:%M:%S %Z"
								  (localtime 
								   (time.make (time (c-pointer 0 'time_t*)))))))
					       (substring timestr 0 len))))))
			  (format p ";;; nrepl: ~A~%~%" timestamp))
			(do ((i 0 (+ i 1)))
			    ((= i ncp-max-row))
			  (if (> (bols i) 0)
			      (format p "~A ~A~%" (ncplane_contents ncp i 0 1 (bols i)) (ncplane_contents ncp i (bols i) 1 (eols i)))
			      (format p "~A~%" (ncplane_contents ncp i 0 1 (eols i)))))))))

	    (set! (top-level-let 'display-status)
		  (lambda (str)
		    (ncplane_putstr_yx ncp (- nc-rows 2) 0 str)
		    (notcurses_render nc)))

	    
	    ;; -------- evaluation ---------
	    (define (badexpr h)            ; *missing-close-paren-hook* function for Enter command
	      (let ((ow (owlet)))
		(if (and (ow 'error-file)
			 (not (equal? (ow 'error-file) "repl.scm")))
		    (error 'syntax-error "missing close paren in ~S" (ow 'error-file))
		    (set! (h 'result) 'string-read-error))))
	    
	    (define (shell? h)             ; *unbound-variable-hook* function, also for Enter
	      (if nrepl-debugging
		  (ncplane_putstr_yx ncp 9 0 (format #f "in shell? ~S ~S ~S ~S ~S" row col (bols (- row 1)) (eols (- row 1)) ((rootlet) 'system))))
	      ;; examine cur-line -- only call system if the unbound variable matches the first non-whitespace chars
	      ;;   of cur-line, and command -v name returns 0 (indicating the shell thinks it is an executable command)
	      (let ((cur-line (ncplane_contents ncp (- row 1) (bols (- row 1)) 1 col)))
		;; at this point (eols row) has not been set, so use col?
		(if nrepl-debugging (ncplane_putstr_yx ncp 11 0 cur-line))
		(do ((i 0 (+ i 1)))
		    ((or (= i (length cur-line))
			 (not (char-whitespace? (cur-line i))))
		     (let ((var-name (symbol->string (h 'variable))))
		       (when (and (>= (- (length cur-line) i) (length var-name)) ; var-name might be unrelated to cur-line
				  (string=? var-name (substring cur-line i (+ i (length var-name))))
				  (zero? (system (string-append "command -v " var-name " >/dev/null"))))
			 (set! unbound-case #t)
			 (if (procedure? ((rootlet) 'system))
			     (set! (h 'result) (((rootlet) 'system) cur-line #t))
			     (set! (h 'result) #f))))))))
	    
	    (define new-eval 
	      (let ((+documentation+ "this is the repl's eval replacement; its default is to use the repl's top-level-let.")
		    (+signature+ '(values #t let?)))
		(lambda (form . rest) ; use lambda (not lambda*) so we can handle forms like :key
		  (let ((e (if (pair? rest) 
			       (car rest)
			       (*nrepl* 'top-level-let))))
		    (let-temporarily (((hook-functions *unbound-variable-hook*) (list shell?)) ; so pwd et al will work
				      ((*s7* 'history-enabled) #t))
		      (eval form e))))))


	    (define (current-expression ncp row)
	      (if (> (bols row) 0)
		  (ncplane_contents ncp row (bols row) 1 (- (eols row) (bols row)))
		  (do ((i (- row 1) (- i 1)))
		      ((not (zero? (bols i)))
		       (let ((expr (ncplane_contents ncp i (bols i) 1 (- (eols i) (bols i)))))
			 (if nrepl-debugging
			     (ncplane_putstr_yx ncp 11 0 (format #f "expr: ~S ~S" expr (eols i))))
			 (do ((nrow (+ i 1) (+ nrow 1)))
			     ((> nrow row)
			      expr)
			   (set! expr (append expr " "
					      (ncplane_contents ncp nrow (bols nrow) 1 (- (eols nrow) (bols nrow)))))))))))

	    ;; -------- match close paren --------
	    (define (match-close-paren ncp row col)
	      ;; if row/col is just after #|), get start of current expr, scan until row/col
	      ;;   return either matching row/col or #f if none
	      (do ((r row (- r 1)))
		  ((> (bols r) 0)
		   
		   (do ((cur-row r (+ cur-row 1))
			(oparens ()))
		       ((> cur-row row)
			(and (pair? oparens)
			     (car oparens)))
		     (let* ((cur-line (ncplane_contents ncp cur-row (bols cur-row) 1 (- (eols cur-row) (bols cur-row))))
			    (len (if (= cur-row row) (- col (bols row) 1) (length cur-line))))
		       
		       (do ((i 0 (+ i 1)))
			   ((>= i len))
			 (case (cur-line i)
			   ((#\()
			    (set! oparens (cons (cons cur-row (+ i (bols cur-row))) oparens)))
			   
			   ((#\))
			    (if (pair? oparens)
				(set! oparens (cdr oparens))))
			   
			   ((#\;)
			    (set! i (+ len 1)))
			   
			   ((#\")
			    (do ((k (+ i 1) (+ k 1)))
				((or (>= k len)
				     (and (char=? (cur-line k) #\")
					  (not (char=? (cur-line (- k 1)) #\\))))
				 (set! i k))))
			   
			   ((#\#)
			    (if (char=? (cur-line (+ i 1)) #\|)
				(do ((k (+ i 1) (+ k 1)))
				    ((or (>= k len)
					 (and (char=? (cur-line k) #\|)
					      (char=? (cur-line (+ k 1)) #\#)))
				     (set! i (+ k 1)))))))))))))

	    ;; -------- indentation --------
	    ;;
	    ;; find last (, send spaces to match its col + some if or/and/cond/etc [might be trailing on cur-row moving back or forward]

	    (define (indent ncp row col)
	      (if (not (zero? (bols row)))
		  col
		   (let ((pars (match-close-paren ncp (- row 1) (eols (- row 1)))))

		     ;; TODO: we're missing a ) at col: (+ (* 2 3)\n4)<tab>

		     (nc-display 25 0 (format #f "pars: ~S" pars))
		     (if pars
			 (let ((new-col (cdr pars))
			       (new-pos (+ col (cdr pars)))
			       (trailer (ncplane_contents ncp row (bols row) 1 (- (eols row) (bols row)))))
			   (nc-display 29 0 (format #f "trailer: ~A" trailer))
			   (do ((i (- (length trailer) 1) (- i 1)))
			       ((or (< i 0)
				    (not (char-whitespace? (trailer i))))
				(if (< i (- (length trailer) 1))
				    (set! trailer (substring trailer 0 (+ i 1))))
				(do ((i 0 (+ i 1)))
				    ((or (= i (length trailer))
					 (not (char-whitespace? (trailer i))))
				     (when (> i 0)
				       (set! new-pos (- new-pos i))
				       (set! trailer (substring trailer i)))))))
			   
					;(nc-display 30 0 (format #f "trailer: ~A" trailer))
			   ;; now fixup new-col and new-pos based on what's after the ( we found above
			   
			   (do ((name (ncplane_contents ncp (car pars) (+ (cdr pars) 1) 1 (eols (car pars))))
				(i 0 (+ i 1)))
			       ((or (= i (length name))
				    (char-whitespace? (name i)))
				;; name = (substring name 0 i))
				(do ((k (+ i 1) (+ k 1)))
				    ((or (>= k (length name))
					 (not (char-whitespace? (name k))))
				     (let ((increment (if (< k (length name))
							  (+ i 2)
							  2)))
				       (set! new-col (+ new-col increment))
				       (set! new-pos (+ new-pos increment)))))))
			   
			   ;; might be moving back, so we need to erase the current line
			   (ncplane_putstr_yx ncp row (bols row) (make-string (- (eols row) (bols row)) #\space))
			   (ncplane_putstr_yx ncp row (bols row) (format #f "~A~A" (make-string (- new-col (bols row)) #\space) trailer))
			   (set! (eols row) (+ new-col (length trailer)))
			   new-pos) ; keep cursor in its relative-to-trailer position
			 (set! (eols row) (bols row))))))
	    

	    (define (clear-line row)
	      (ncplane_putstr_yx ncp row 0 (make-string (eols row) #\space)))
	    
	    (define (reprompt y)
	      (ncplane_cursor_move_yx ncp y 0)
	      (ncplane_putstr_yx ncp y 0 prompt)
	      (notcurses_render nc)
	      (move-cursor ncd y prompt-len)
	      (set! (bols row) prompt-len)
	      (set! (eols row) prompt-len)
	      (set! col prompt-len)
	      (set! row y))

	    (define (display-error ncp row type info)
	      (ncplane_putstr_yx ncp row 0 "error:")
	      (set! (eols row) 7)
	      (let ((op (*s7* 'print-length)))
		(if (< op nc-cols) (set! (*s7* 'print-length) nc-cols))
		(if (and (pair? info)
			 (string? (car info)))
		    (let ((err (apply format #f info)))
		      (ncplane_putstr_yx ncp row 7 err)
		      (set! (eols row) (+ (length err) 7)))
		    (if (not (null? info))
			(let ((err (format #f "~S" info)))
			  (ncplane_putstr_yx ncp row 1 err)
			  (set! (eols row) (+ (length err) 7)))))
		(if (< op nc-cols) (set! (*s7* 'print-length) op)))
	      row)

	    
	    (ncplane_putstr_yx ncp (- nc-rows 3) 0 (make-string nc-cols #\_))
	    (reprompt 0)
	    
	    (catch #t
	      (lambda ()
		(let ((ni (ncinput_make))
		      (selection #f)
		      (mouse-col #f)
		      (mouse-row #f)
		      (error-row #f))
		  
		  (do ((c (notcurses_getc nc (c-pointer 0) (c-pointer 0) ni)
			  (notcurses_getc nc (c-pointer 0) (c-pointer 0) ni))
		       (c-ctr 0 (+ c-ctr 1)))
		      ((and (= c (char->integer #\Q))
			    (ncinput_ctrl ni))
		       (set! (top-level-let 'history) old-history))
		    
		    (when nrepl-debugging
		      (ncplane_putstr_yx ncp 15 0 (make-string 80 #\space))
		      (ncplane_putstr_yx ncp 15 0 (format #f "loop body ~S: start: ~S col: ~S end: ~S" c-ctr (bols row) col (eols row))))
		    
		    (cond
		     
		     ;; normal character typed
		     ((and (< c 256)
			   (not (ncinput_ctrl ni)))
		      
		      (if (and nrepl-debugging
			       (= c (char->integer #\tab)))
			  (ncplane_putstr_yx ncp 18 0 (format #f "~S: bol: ~S col: ~S eol: ~S" c-ctr (bols row) col (eols row))))
		      
		      (if (= c (char->integer #\tab))

			  (if (< col (eols row))
			      (set! col (indent ncp row col))
			      
			      (let ((start (bols row))
				    (end (eols row)))
				(if (= end start)
				    (begin
				      (ncplane_putstr_yx ncp row end "    ")
				      (set! (eols row) (+ end 4))
				      (set! col (+ col 4)))
				    
				    (let ((cur-line (ncplane_contents ncp row (bols row) 1 (- (eols row) (bols row)))))
				      
				      (when nrepl-debugging
					(ncplane_putstr_yx ncp 19 0 (make-string 80 #\space))
					(ncplane_putstr_yx ncp 19 0 (format #f "~S: start: ~S end: ~S col: ~S cur-line: ~S" c-ctr start end col cur-line)))
				      
				      (let ((completion #f)
					    (loc (do ((i (- (length cur-line) 1) (- i 1)))
						     ((or (< i 0)
							  (char-whitespace? (cur-line i))
							  (memv (cur-line i) '(#\( #\' #\" #\))))
						      i))))
					(set! completion (if (< loc 0) ; match whole cur-line
							     (symbol-completion cur-line)
							     ((if (char=? (cur-line loc) #\") filename-completion symbol-completion)
							      (substring cur-line (+ loc 1)))))
					
					(when nrepl-debugging
					  (ncplane_putstr_yx ncp 20 0 (make-string 80 #\space))
					  (ncplane_putstr_yx ncp 20 0 (format #f "~S: completion: ~S loc: ~S len: ~S" c-ctr completion loc (length completion))))
					
					(if (not completion)
					    (set! col (indent ncp row col)))
					
					(when (and completion
						   (not (string=? completion cur-line)))
					  
					  (when (>= loc 0)
					    (set! completion (string-append (substring cur-line 0 (+ loc 1)) completion))
					    (if (char=? (cur-line loc) #\")
						(set! completion (string-append completion "\""))))
					  
					  (ncplane_putstr_yx ncp row (bols row) completion)
					  (set! col (+ (bols row) (length completion)))
					  (set! (eols row) col)
					  
					  (if nrepl-debugging 
					      (ncplane_putstr_yx ncp 21 0 (make-string 80 #\space))))
					(if nrepl-debugging
					    (ncplane_putstr_yx ncp 21 0 (format #f "tab end: ~S ~S" col (eols row))))
					))
				    )))
			  
			  (begin ; not tab
			    (when nrepl-debugging
			      (ncplane_putstr_yx ncp 16 0 (make-string 80 #\space))
			      (ncplane_putstr_yx ncp 16 0 (format #f "~S: bol: ~S col: ~S eol: ~S" c-ctr (bols row) col (eols row))))
			    
			    (let ((trailing (and (> (eols row) col)
						 (ncplane_contents ncp row col 1 (- (eols row) col -1)))))
			      (ncplane_putstr_yx ncp row col (string (integer->char c)))
			      (if (and trailing (> (length trailing) 0))
				  (ncplane_putstr_yx ncp row (+ col 1) trailing)))
			    
			    (if (char=? (integer->char c) #\space)
				(notcurses_refresh nc))
			    (set! col (+ col 1)) ; might be midline
			    (set! (eols row) (+ (eols row) 1)) ; in any case we've added a character
			    
			    (when nrepl-debugging
			      (ncplane_putstr_yx ncp 17 0 (make-string 80 #\space))
			      (ncplane_putstr_yx ncp 17 0 (format #f "~S: ~C: bol: ~S col: ~S eol: ~S" c-ctr (integer->char c) (bols row) col (eols row))))
			    )
			  ;; (if (> (- col ncp-col) ncp-cols) (plane-expand-rows ncp col))
			  ;; (if (< nc-cols (+ (- col ncp-col) ncp-nc-col)) (scroll-plane-right ncp))
			  ))
		     
		     
		     ;; terminal window resized
		     ((= c NCKEY_RESIZE)
		      (let ((new-size (ncplane_dim_yx (notcurses_stdplane nc))))
			(set! nc-cols (cadr new-size))
			(set! nc-rows (car new-size))))
		     ;; perhaps scroll so cursor is in view
		     
		     
		     ;; backspace
		     ((= c NCKEY_BACKSPACE)
		      (when (> col (bols row))
			(let ((trailing (and (> (eols row) col)
					     (ncplane_contents ncp row col 1 (- (eols row) col -1)))))
			  (if trailing
			      (begin
				(ncplane_putstr_yx ncp row (- col 1) trailing)
				(ncplane_putstr_yx ncp row (+ col (- (length trailing) 1)) " "))
			      (ncplane_putstr_yx ncp row (- col 1) " "))
			  
			  (set! (eols row) (- (eols row) 1))
			  (set! col (- col 1)))))
		     ;; if we backspaced past ncp-col, scroll-left
		     
		     ;; mouse click
		     ((= c NCKEY_BUTTON1) ; doesn't work in rxvt apparently
		      (set! row (min ncp-max-row (ncinput_y ni)))
		      (set! col (min (eols row) (max (ncinput_x ni) (bols row))))
		      (when (not mouse-col)
			(set! mouse-col col)
			(set! mouse-row row)))
		     
		     ((= c NCKEY_RELEASE)
		      (if nrepl-debugging
			  (ncplane_putstr_yx ncp 12 0 (format #f "mouse: ~S ~S to ~S ~S" mouse-row mouse-col (ncinput_y ni) (ncinput_x ni))))
		      ;; TODO: selection here could be multiline, but for now...
		      ;; TODO: highlight selected text
		      (when (and mouse-col (not (= col mouse-col)))
			(set! selection (ncplane_contents ncp mouse-row (min col mouse-col) 1 (abs (- col mouse-col)))))
		      (set! mouse-col #f))
		     
		     
		     ;; enter: either eval/print or insert newline
		     ((= c NCKEY_ENTER)
		      
		      (let ((cur-line (current-expression ncp row)))
			(when nrepl-debugging
			  (ncplane_putstr_yx ncp 12 0 (make-string 80 #\space))
			  (ncplane_putstr_yx ncp 12 0 (format #f "expr: ~S ~S" cur-line (bols row))))
			
			(set! row (+ row 1))
			(set! ncp-max-row (max ncp-max-row row))
			
			(if (> (eols row) 0)
			    (clear-line row))
			
			(call-with-exit
			 (lambda (return)
			   (let ((len (length cur-line)))
			     
			     (do ((i 0 (+ i 1)))               ; check for just whitespace
				 ((or (= i len)
				      (not (char-whitespace? (cur-line i))))
				  (when (= i len)
				    (set! (eols row) col)
				    (return))))
			     
			     (catch #t
			       (lambda ()
				 
				 (catch 'string-read-error ; this matches (throw #t 5) -- is this correct? *missing-close-paren-hook* returns 'string-read-error
				   
				   (lambda ()
				     
				     ;; get the newline out if the expression does not involve a read error
				     (let-temporarily (((hook-functions *missing-close-paren-hook*) (list badexpr)))
				       
				       (let ((form (with-input-from-string cur-line #_read)))    ; not libc's read
					 
					 (let ((val (list (new-eval form (*nrepl* 'top-level-let))))) ; list, not lambda -- confuses trace!
					   
					   (when nrepl-debugging
					     (ncplane_putstr_yx ncp 23 0 (make-string 80 #\space))
					     (ncplane_putstr_yx ncp 23 0 (format #f "val: ~S unbound: ~S" val unbound-case)))
					   
					   (if (or (null? val)   ; try to trap (values) -> #<unspecified>
						   (and (unspecified? (car val))
							(null? (cdr val))))
					       (set! val #<unspecified>)
					       (set! val (if (pair? (cdr val))  ; val is a list, it must have caught multiple values if cdr is a pair
							     (cons 'values val)
							     (car val))))
					   
					   (if unbound-case
					       (begin
						 (set! unbound-case #f)
						 (ncplane_putstr_yx ncp row 0 (format #f "~A" (substring val 0 (- (length val) 1))))
						 (set! (eols row) (length val)))
					       (let* ((str (object->string val))
						      (len (length str)))
						 (if (char-position #\newline str)
						     (do ((start 0)
							  (i 0 (+ i 1)))
							 ((= i len)
							  (ncplane_putstr_yx ncp row 0 (substring str start len))
							  (set! (eols row) (- len start)))
						       (if (char=? #\newline (str i))
							   (begin
							     (ncplane_putstr_yx ncp row 0 (substring str start i))
							     (set! (eols row) (- i start)))
							   (set! row (+ row 1))
							   (set! ncp-max-row (max ncp-max-row row))
							   (set! start (+ i 1)))))
						 (ncplane_putstr_yx ncp row 0 str)
						 (set! (eols row) (length str))))
					   ))))
				   
				   
				   (lambda (type info)
				     (if (eq? type 'string-read-error)
					 (begin
					   ;; missing close paren, newline already added, spaces here are not optional!
					   (ncplane_putstr_yx ncp row 0 (make-string col #\space))
					   (set! (eols row) col)
					   (return))
					 (apply throw type info)))))   ; re-raise error
			       
			       (lambda (type info)
				 (set! error-row (display-error ncp row type info))))
				   
			     (set! row (+ row 1))
			     (set! ncp-max-row (max ncp-max-row row))
			     (reprompt row)
					;(notcurses_render nc)
			     (notcurses_refresh nc)
			     )))))
		     
		     ((= c NCKEY_LEFT)
		      (set! col (max (bols row) (- col 1))))
		     
		     ((= c NCKEY_RIGHT)
		      (set! col (min (eols row) (+ col 1))))
		     
		     ((= c NCKEY_UP)
		      (set! row (max 0 (- row 1)))
		      (set! col (min (max col (bols row)) (eols row))))
		     
		     ((= c NCKEY_DOWN)
		      (set! row (+ row 1))
		      (set! ncp-max-row (max ncp-max-row row))
		      (set! col (min (max col (bols row)) (eols row))))
		     ;; TODO: see below if multiline -- should we go on past current entry?
		     
		     ((ncinput_ctrl ni)
		      (case c		     
			
			((68) ; #\d
			 (when (> (eols row) (bols row))
			   (let ((trailing (ncplane_contents ncp row (+ col 1) 1 (- (eols row) col -1))))
			     (ncplane_putstr_yx ncp row col trailing)
			     (ncplane_putstr_yx ncp row (+ col (length trailing)) " "))
			   (set! (eols row) (- (eols row) 1))))
			
			((65) ; #\a
			 (set! col (bols row)))
			;; if offscreen scroll?
			
			((66) ; #\b
			 (if (and (= col (bols row))
				  (> row 0))
			     (begin
			       (set! row (- row 1))
			       (set! col (eols row)))
			     (set! col (max (bols row) (- col 1)))))
			
			((69) ; #\e
			 (set! col (eols row)))
			
			((70) ; #\f
			 (if (and (= col (eols row))
				  (< row ncp-max-row))
			     (begin
			       (set! row (+ row 1))
			       (set! ncp-max-row (max ncp-max-row row))
			       (set! col (bols row)))
			     (set! col (min (eols row) (+ col 1)))))
			
			((75) ; #\k
			 (set! selection (ncplane_contents ncp row col 1 (- (eols row) col -1)))
			 (ncplane_putstr_yx ncp row col (make-string (- (eols row) col) #\space))
			 (set! (eols row) col))
			
			((78) ; #\n
			 (set! row (+ row 1))
			 (set! ncp-max-row (max ncp-max-row row))
			 (set! col (min (max col (bols row)) (eols row))))
			
			((80) ; #\p
			 (set! row (max 0 (- row 1)))
			 (set! col (min (max col (bols row)) (eols row))))
			
			((89) ; #\y
			 (when (string? selection)
			   (let ((trailing (and (> (eols row) col)
						(ncplane_contents ncp row col 1 (- (eols row) col -1)))))
			     (ncplane_putstr_yx ncp 12 0 (format #f "~D: sel: [~S] ~D, trail: [~S]~%" c selection (length selection) trailing))
			     (ncplane_putstr_yx ncp row col selection)
			     (if (and trailing 
				      (> (length trailing) 0))
				 (ncplane_putstr_yx ncp row (+ col (length selection)) trailing)))
			   (set! (eols row) (+ (eols row) (length selection)))))
			
			))
		     )
		    
		    (when nrepl-debugging
		      (ncplane_putstr_yx ncp 14 0 (make-string 80 #\space))
		      (ncplane_putstr_yx ncp 14 0 (format #f "loop end ~S: c: ~S start: ~S col: ~S end: ~S" c-ctr c (bols row) col (eols row))))

		    (notcurses_render nc)
		    
		    (when (integer? error-row)
		      (move-cursor ncd error-row 0)
		      (ncdirect_fg ncd #xff0000)
		      (format *stdout* "error:")
		      (ncdirect_fg_default ncd)
		      (set! error-row #f))

		    ;; if cursor is after ), look for matching open, highlight if found
		    (when prev-pars
		      (move-cursor ncd (car prev-pars) (cdr prev-pars))
		      (format *stdout* "(")
		      (set! prev-pars #f))

		    (unless (or (<= col (+ (bols row) 1)) ; got to be room for #\(
				(not (string=? ")" (ncplane_contents ncp row (- col 1) 1 1)))
				(and (>= col (+ (bols row) 3))
				     (string=? (ncplane_contents ncp row (- col 3) 1 3) "#\\)")))
		      (let ((pars (match-close-paren ncp row col)))
			(when pars
			  (move-cursor ncd (car pars) (cdr pars))
			  (ncdirect_fg ncd #xff0000)
			  (format *stdout* "(")
			  (ncdirect_fg_default ncd)
			  (set! prev-pars pars))))
		    
		    (move-cursor ncd row col)
		    
		    )))
	      
	      (lambda (type info)
		(notcurses_stop nc)
		(apply format *stderr* info)
		(format *stderr* "~%line ~A: ~A~%" ((owlet) 'error-line) ((owlet) 'error-code))
#|
		(let ((elist (list () (rootlet) *libc*)))
		  ;; show the enclosing contexts
		  (let-temporarily (((*s7* 'print-length) 8))
		    (do ((e (outlet (owlet)) (outlet e)))
			((memq e elist))
		      (if (and (number? (length e)) ; with-let + mock-data + length method?
			       (> (length e) 0))
			  (format *stderr* "~%~{~A~| ~}~%" e)
			  (format *stderr* "e: ~S~%" e))
		      (set! elist (cons e elist)))))
|#
		(#_exit)
		)
	      )
	    ))) ; run
      
      
      (define (stop)
	(notcurses_stop nc)
	(#_exit))
      
      
      (define (start)
	(set! ncd (ncdirect_init (c-pointer 0)))
	(let ((noptions (notcurses_options_make)))
	  (set! (notcurses_options_flags noptions) NCOPTION_SUPPRESS_BANNERS)
	  (set! nc (notcurses_init noptions)))
	(notcurses_cursor_enable nc)
	(unless (string-position "rxvt" ((*libc* 'getenv) "TERM"))
	  (notcurses_mouse_enable nc))
	(let ((size (ncplane_dim_yx (notcurses_stdplane nc))))
	  (set! nc-cols (cadr size))
	  (set! nc-rows (car size))))
      
      (curlet)))
  
  (with-let *nrepl*
    (start)
    (run)
    (stop)))


;; TODO: C-o C-_ how to get M-*?  use function table so it's easy to add/change editing choices
;; PERHAPS: box at bottom showing signatures: see glistener, [hover->underline] if clicked -> object->let in a box
;;          nrepl eval access to status area (and remember to move it)
;; TODO: scroll all directions, resize as necessary, test recursive call, check other prompts
;; TODO: stack/let-trace if error
;; TODO: watch vars (debug.scm) in floating boxes?
;; PERHAPS: if several completions, display somewhere
;; from repl: drop-into-repl+debug.scm connection
;; xclip access the clipboard?? (system "xclip -o")=current contents, (system "echo ... | xclip")=set contents
;;   so if middle mouse=get from xclip if it exists etc, or maybe add example function, also selection-setter/getter
;; preload libc/notcurses

(set! (*s7* 'debug) old-debug)
*nrepl*