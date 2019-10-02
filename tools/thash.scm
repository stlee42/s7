(set! (*s7* 'heap-size) (* 5 1024000))
;(set! (*s7* 'gc-stats) 6)

(define (reader)
  (let ((port (open-input-file "/home/bil/test/scheme/bench/src/bib"))
	(counts (make-hash-table))
	(start 0)
	(end 0)
	(new-pos 0))
    (do ((line (read-line port) (read-line port)))
	((eof-object? line))
      (set! new-pos 0)
      (do ((pos (char-position #\space line) (char-position #\space line (+ pos 1))))
	  ((not pos))
	(unless (= pos new-pos)
	  (set! start 
		(if (char-alphabetic? (string-ref line new-pos))
		    new-pos
		    (do ((k (+ new-pos 1) (+ k 1))) ; char-position here is slower!
			((or (char-alphabetic? (string-ref line k))
			     (>= k pos))
			 k))))
	  (set! end 
		(if (char-alphabetic? (string-ref line (- pos 1)))
		    pos
		    (do ((k (- pos 2) (- k 1)))
			((or (char-alphabetic? (string-ref line k))
			     (<= k start))
			 (+ k 1)))))
	  (when (> end start)
	    (let ((word (string->symbol (substring line start end))))
	      (hash-table-set! counts word (+ (or (hash-table-ref counts word) 0) 1)))))
	(set! new-pos (+ pos 1))))
    
    (close-input-port port)
    (let ((res (sort! (copy counts (make-vector (hash-table-entries counts)))
		      (lambda (a b) (> (cdr a) (cdr b))))))
      (set! counts #f)
      res)))

(format *stderr* "reader ")

(let ((counts (reader)))
  (if (not (and (eq? (car (counts 0)) 'the)
		(= (cdr (counts 0)) 62063)))
      (do ((i 0 (+ i 1))) 
	  ((= i 40)) 
	(format *stderr* "~A: ~A~%" (car (counts i)) (cdr (counts i))))))

;;; ----------------------------------------

(let ()
  (define (walk p counts)
    (if (pair? p)
	(begin
	  (walk (car p) counts)
	  (if (pair? (cdr p))
	      (walk (cdr p) counts)))
	(hash-table-set! counts p (+ (or (hash-table-ref counts p) 0) 1))))
  
  (define (s7test-reader)
    (let ((port (open-input-file "/home/bil/cl/s7test.scm"))
	  (counts (make-hash-table)))
      (do ((expr (read port) (read port)))
	  ((eof-object? expr) 
	   counts)
	(walk expr counts))))
  
  (define (sort-counts counts)
    (let ((len (hash-table-entries counts)))
      (do ((v (make-vector len))
	   (h (make-iterator counts))
	   (i 0 (+ i 1)))
	  ((= i len)
	   (sort! v (lambda (e1 e2) (> (cdr e1) (cdr e2))))
	   v)
	(vector-set! v i (iterate h)))))
  
  (sort-counts (s7test-reader)))

;;; ----------------------------------------

(let ()
  (define (hash-ints)
    (let ((counts (make-hash-table)))
      (do ((i 0 (+ i 1))
	   (z (random 100) (random 100)))
	  ((= i 5000000) counts)
	(hash-table-set! counts z (+ (or (hash-table-ref counts z) 0) 1)))))

  (hash-ints))

;;; ----------------------------------------

(define symbols (make-vector 1))
(define strings (make-vector 1))

(define (test1 size)
  (let ((int-hash (make-hash-table size))
	(p (cons #f #f)))
    (do ((i 0 (+ i 1))) 
	((= i size))
      (hash-table-set! int-hash i i))
    (do ((i 0 (+ i 1)))	
	((= i size))
      (if (not (= (hash-table-ref int-hash i) i))
	  (display "oops")))
    (for-each (lambda (key&value)
		(if (not (= (car key&value) (cdr key&value)))
		    (display "oops"))) ;(format *stderr* "hash iter ~A~%" key&value)))
	      (make-iterator int-hash p))
    (set! int-hash #f)))

(define (test2 size)
  (let ((int-hash (make-hash-table size =)))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (hash-table-set! int-hash i i))
    (do ((i 0 (+ i 1)))	
	((= i size))
      (if (not (= (hash-table-ref int-hash i) i))
	  (display "oops")))
    (set! int-hash #f)))

(define (test3 size)
  (let ((flt-hash (make-hash-table size)))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (hash-table-set! flt-hash (* i 2.0) i))
    (do ((i 0 (+ i 1)))	
	((= i size))
      (if (not (= (hash-table-ref flt-hash (* 2.0 i)) i))
	  (display "oops")))
    (set! flt-hash #f)))

(define (test4 size)
  (let ((sym-hash (make-hash-table size)))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (hash-table-set! sym-hash (vector-set! symbols i (string->symbol (vector-set! strings i (number->string i)))) i))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (if (not (= (hash-table-ref sym-hash (vector-ref symbols i)) i)) 
	  (display "oops")))
    (set! sym-hash #f)))

(define (test5 size)
  (let ((str-hash (make-hash-table size eq?)))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (hash-table-set! str-hash (vector-ref strings i) i))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (if (not (= (hash-table-ref str-hash (vector-ref strings i)) i)) 
	  (display "oops")))
    (set! str-hash #f)))

(define (test6 size)
  (let ((sym-hash (make-hash-table size eq?)))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (hash-table-set! sym-hash (vector-ref symbols i) i))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (if (not (= (hash-table-ref sym-hash (vector-ref symbols i)) i)) 
	  (display "oops")))
    (set! sym-hash #f)))

(define (test7 size)
  (let ((chr-hash (make-hash-table 256 char=?)))
    (do ((i 0 (+ i 1))) 
	((= i 256)) 
      (hash-table-set! chr-hash (integer->char i) i))
    (do ((i 0 (+ i 1))) 
	((= i 256)) 
      (if (not (= (hash-table-ref chr-hash (integer->char i)) i))
	  (display "oops")))
    (set! chr-hash #f)))

(define (test8 size)
  (let ((any-hash (make-hash-table size eq?)))
    (if (= size 1)
	(hash-table-set! any-hash (vector-set! strings 0 (list 0)) 0)
	(begin
	  (do ((i 0 (+ i 2)))
	      ((= i size))
	    (hash-table-set! any-hash (vector-set! strings i (list i)) i))
	  (do ((j 1 (+ j 2)))
	      ((>= j size))
	    (hash-table-set! any-hash (vector-set! strings j (int-vector j)) j))))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (if (not (= i (hash-table-ref any-hash (vector-ref strings i))))
	  (display "oops")))
    (set! any-hash #f)))

(define (test9 size)
  (let ((any-hash1 (make-hash-table size eq?)))
    (if (= size 1)
	(hash-table-set! any-hash1 (vector-set! strings 0 (inlet 'a 0)) 0)
	(begin
	  (do ((i 0 (+ i 2)))
	      ((= i size))
	    (hash-table-set! any-hash1 (vector-set! strings i (inlet 'a i)) i))
	  (do ((j 1 (+ j 2))
	       (x 0.0 (+ x 2.0)))
	      ((>= j size))
	    (hash-table-set! any-hash1 (vector-set! strings j (float-vector x)) j))))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (if (not (= i (hash-table-ref any-hash1 (vector-ref strings i))))
	  (display "oops")))
    (vector-fill! strings #f)
    (set! any-hash1 #f)))

(define (test10 size)
  (let ((cmp-hash (make-hash-table size =)))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (hash-table-set! cmp-hash (complex i i) i))
    (do ((i 0 (+ i 1))) 
	((= i size)) 
      (if (not (= (hash-table-ref cmp-hash (complex i i)) i)) 
	  (display "oops")))
    (set! cmp-hash #f)))

(define (test-hash size)
  (format *stderr* "~D " size)
  (set! symbols (make-vector size))
  (set! strings (make-vector size))
  (test1 size)
  (test2 size)
  (test3 size)
  (test4 size)
  (test5 size)
  (test6 size)
  (test7 size)
  (test8 size)
  (test9 size)
  (test10 size))

(for-each test-hash (list 1 10 100 1000 10000 100000 1000000))
(newline)

(exit)
