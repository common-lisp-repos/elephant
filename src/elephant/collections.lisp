;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; collections.lisp -- view Berkeley DBs as Lisp collections
;;; 
;;; Initial version 8/26/2004 by Ben Lee
;;; <blee@common-lisp.net>
;;; 
;;; part of
;;;
;;; Elephant: an object-oriented database for Common Lisp
;;;
;;; Copyright (c) 2004 by Andrew Blumberg and Ben Lee
;;; <ablumberg@common-lisp.net> <blee@common-lisp.net>
;;;
;;; Portions Copyright (c) 2005-2007 by Robert Read and Ian Eslick
;;; <rread common-lisp net> <ieslick common-lisp net>
;;;
;;; Elephant users are granted the rights to distribute and use this software
;;; as governed by the terms of the Lisp Lesser GNU Public License
;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;

(in-package "ELEPHANT")

#-elephant-without-optimize
(declaim (optimize speed (safety 0) (space 0) (debug 0)))

;; 
;; Our workhorse BTree
;;

(defun make-btree (&optional (sc *store-controller*))
  "Constructs a new BTree instance for use by the user.  Each backend
   returns its own internal type as appropriate and ensures that the 
   btree is associated with the store-controller that created it."
  (build-btree sc))

(defgeneric build-btree (sc)
  (:documentation 
   "Construct a btree of the appropriate type corresponding to this store-controller."))

(defclass btree (persistent-collection) ()
  (:documentation 
   "A hash-table like interface to a BTree, which stores things 
    in a semi-ordered fashion."))

(defgeneric get-value (key bt)
  (:documentation "Get a value from a Btree."))

(defgeneric (setf get-value) (value key bt)
  (:documentation "Put a key / value pair into a BTree."))

(defgeneric remove-kv (key bt)
  (:documentation "Remove a key / value pair from a BTree."))

(defgeneric existsp (key bt)
  (:documentation "Test existence of a key / value pair in a BTree"))

(defmethod optimize-layout ((bt t) &key &allow-other-keys)
  t)

(defmethod drop-instance ((bt btree))
  "The standard method for reclaiming storage of persistent objects"
  (ensure-transaction (:store-controller (get-con bt))
    (drop-btree bt)
    (call-next-method)))

(defgeneric drop-btree (bt)
  (:documentation "Delete all key-value pairs from the btree and
   render it an invalid object in the data store"))


;;
;; Btrees that support secondary indices
;;

(defun make-indexed-btree (&optional (sc *store-controller*))
  "Constructs a new indexed BTree instance for use by the user.
   Each backend returns its own internal type as appropriate and
   ensures that the btree is associated with the store-controller
   that created it."
  (build-indexed-btree sc))

(defgeneric build-indexed-btree (sc)
  (:documentation 
   "Construct a btree of the appropriate type corresponding to this store-controller."))

(defclass indexed-btree (btree) ()
  (:documentation "A BTree which supports secondary indices."))

(defgeneric add-index (bt &key index-name key-form populate)
  (:documentation 
   "Add a secondary index.  The indices are stored in an eq
hash-table, so the index-name should be a symbol.  key-form
should be a symbol naming a function, a function call form
eg \'(create-index 3) or a lambda expression -- 
actual functions aren't supported.
Lambda expresssions are converted to functions through compile
and function call forms are transformed applying
the first element of the list to the rest of the list.
The function should take 3 arguments: the secondary DB, primary
key and value, and return two values: a boolean indicating
whether to index this key / value, and the secondary key if
so.  If populate = t it will fill in secondary keys for
existing primary entries (may be expensive!)"))

(defgeneric get-index (bt index-name)
  (:documentation "Get a named index."))

(defgeneric remove-index (bt index-name)
  (:documentation "Remove a named index."))

(defgeneric map-indices (fn bt)
  (:documentation "Calls a two input function with the name and 
   btree-index object of all secondary indices in the btree"))

(defmethod ensure-index ((ibt indexed-btree) idxname &key key-form populate)
  (ifret (get-index ibt idxname)
	 (add-index ibt :index-name idxname :key-form key-form :populate populate)))

;;
;; Secondary Indices
;;

(defgeneric build-btree-index (sc &key name primary key-form)
  (:documentation 
   "Construct a btree of the appropriate type corresponding to this store-controller."))

(defclass btree-index (btree)
  ((primary :type indexed-btree :reader primary :initarg :primary)
   (key-form :reader key-form :initarg :key-form :initform nil)
   (key-fn :type function :accessor key-fn :transient t))
  (:metaclass persistent-metaclass)
  (:documentation "Secondary index to an indexed-btree."))

(define-condition invalid-keyform (error)
  ((key-form :reader key-form-of :initarg :key-form))
  (:report (lambda (c s)
             (format s "~S is an invalid key form for an index."
                     (key-form-of c)))))

(defun function<-keyform (key-form)
  (cond ((and (symbolp key-form) (fboundp key-form))
         (fdefinition key-form))
        ((and (consp key-form) (eql (first key-form) 'lambda)) 
         (compile nil key-form))
        ((consp key-form)
         (apply (first key-form) (rest key-form)))
        (t (error 'invalid-keyform :key-form key-form))))

(defmethod shared-initialize :after ((instance btree-index) slot-names
				     &rest rest)
  (declare (ignore slot-names rest))
  (setf (key-fn instance) (function<-keyform (key-form instance))))

(defgeneric get-primary-key (key bt)
  (:documentation "Get the primary key from a secondary key."))

;;
;; Some generic defaults for secondary indices 
;; (shouldn't implement in backend)
;;

(defmethod (setf get-value) (value key (bt btree-index))
  "Puts are not allowed on secondary indices.  Try adding to
the primary."
  (declare (ignore value key)
	   (ignorable bt))
  (error "Puts are forbidden on secondary indices.  Try adding to the primary."))

(defmethod remove-kv (key (bt btree-index))
  "Remove a key / value from the PRIMARY by a secondary
lookup, updating ALL other secondary indices."
  (remove-kv (get-primary-key key bt) (primary bt)))

;;
;; Duplicate btrees
;;

(defclass dup-btree (btree) ())

(defgeneric build-dup-btree (sc)
  (:documentation 
   "Construct a btree of the appropriate type corresponding to this store-controller."))

(defun make-dup-btree (&optional (sc *store-controller*))
  (build-dup-btree sc))

;;
;; Cursors for all btree types
;;

(defclass cursor ()
  ((oid :accessor cursor-oid :type fixnum :initarg :oid)
   (initialized-p :accessor cursor-initialized-p
		  :type boolean :initform nil :initarg :initialized-p
		  :documentation "Predicate indicating whether
the btree in question is initialized or not.  Initialized means
that the cursor has a legitimate position, not that any
initialization action has been taken.  The implementors of this
abstract class should make sure that happens under the
sheets...  Cursors are initialized when you invoke an operation
that sets them to something (such as cursor-first), and are
uninitialized if you move them in such a way that they no longer
have a legimtimate value.")
   (btree :accessor cursor-btree :initarg :btree))
  (:documentation "A cursor for traversing (primary) BTrees."))

(defgeneric make-cursor (bt)
  (:documentation "Construct a cursor for traversing BTrees."))

(defgeneric make-simple-cursor (bt)
  (:documentation "Allow users to walk secondary indices and only 
                   get back primary keys rather than associated 
                   primary values"))

(defgeneric cursor-close (cursor)
  (:documentation 
   "Close the cursor.  Make sure to close cursors before the
enclosing transaction is closed!"))

(defgeneric cursor-duplicate (cursor)
  (:documentation "Duplicate a cursor."))

(defgeneric cursor-current (cursor)
  (:documentation 
   "Get the key / value at the cursor position.  Returns
has-pair key value, where has-pair is a boolean indicating
there was a pair."))

(defgeneric cursor-first (cursor)
  (:documentation 
   "Move the cursor to the beginning of the BTree, returning
has-pair key value."))

(defgeneric cursor-last (cursor)
  (:documentation 
   "Move the cursor to the end of the BTree, returning
has-pair key value."))

(defgeneric cursor-next (cursor)   
  (:documentation 
   "Advance the cursor, returning has-pair key value."))

(defgeneric cursor-prev (cursor)
  (:documentation 
   "Move the cursor back, returning has-pair key value."))

(defgeneric cursor-set (cursor key)
  (:documentation 
   "Move the cursor to a particular key, returning has-pair
key value."))

(defgeneric cursor-set-range (cursor key) 
  (:documentation 
   "Move the cursor to the first key-value pair with key
greater or equal to the key argument, according to the lisp
sorter.  Returns has-pair key value."))

(defclass secondary-cursor (cursor) ()
  (:documentation "Cursor for traversing secondary indices."))

(defgeneric cursor-get-both (cursor key value)
  (:documentation 
   "Moves the cursor to a particular key / value pair,
returning has-pair key value.")
  (:method :before ((cursor secondary-cursor) key value)
    (declare (ignore key value) (ignorable cursor))
    (error "Cannot use get-both on secondary cursor; use pget-both")))

(defgeneric cursor-get-both-range (cursor key value)
  (:documentation 
   "Moves the cursor to the first key / value pair with key
equal to the key argument and value greater or equal to the
value argument.  Not really useful for us since primaries
don't have duplicates.  Returns has-pair key value.")
  (:method :before ((cursor secondary-cursor) key value)
    (declare (ignore key value) (ignorable cursor))
    (error "Cannot use get-both-range on secondary cursor; use pget-both-range")))

(defgeneric cursor-delete (cursor)
  (:documentation 
   "Delete by cursor.  The cursor is at an invalid position,
and uninitialized, after a successful delete."))

(defgeneric cursor-put (cursor value &key key)
  (:documentation 
  "Overwrite value at current cursor location.  Cursor remains
   at the current location")
  (:method :before ((cursor secondary-cursor) value &key key)
    (declare (ignore key value) (ignorable cursor))
    (error "Cannot use put on a secondary cursor; use (setf get-value) on primary")))

(defgeneric cursor-pcurrent (cursor)
  (:documentation 
   "Returns has-tuple / secondary key / value / primary key
at the current position."))

(defgeneric cursor-pfirst (cursor)
  (:documentation 
   "Moves the key to the beginning of the secondary index.
Returns has-tuple / secondary key / value / primary key."))

(defgeneric cursor-plast (cursor)
  (:documentation 
   "Moves the key to the end of the secondary index.  Returns
has-tuple / secondary key / value / primary key."))

(defgeneric cursor-pnext (cursor)
  (:documentation 
   "Advances the cursor.  Returns has-tuple / secondary key /
value / primary key."))

(defgeneric cursor-pprev (cursor)
  (:documentation 
   "Moves the cursor back.  Returns has-tuple / secondary key
/ value / primary key."))

(defgeneric cursor-pset (cursor key)
  (:documentation 
  "Moves the cursor to a particular key.  Returns has-tuple
/ secondary key / value / primary key."))

(defgeneric cursor-pset-range (cursor key)
  (:documentation 
   "Move the cursor to the first key-value pair with key
greater or equal to the key argument, according to the lisp
sorter.  Returns has-pair secondary key value primary key."))

(defgeneric cursor-pget-both (cursor key value)
  (:documentation 
   "Moves the cursor to a particular secondary key / primary
key pair.  Returns has-tuple / secondary key / value /
primary key."))

(defgeneric cursor-pget-both-range (cursor key value)
  (:documentation 
   "Moves the cursor to a the first secondary key / primary
key pair, with secondary key equal to the key argument, and
primary key greater or equal to the pkey argument.  Returns
has-tuple / secondary key / value / primary key."))

(defgeneric cursor-next-dup (cursor)
  (:documentation 
   "Move to the next duplicate element (with the same key.)
Returns has-pair key value."))

(defgeneric cursor-next-nodup (cursor)
  (:documentation 
   "Move to the next non-duplicate element (with different
key.)  Returns has-pair key value."))

(defgeneric cursor-pnext-dup (cursor)
  (:documentation 
   "Move to the next duplicate element (with the same key.)
Returns has-tuple / secondary key / value / primary key."))

(defgeneric cursor-pnext-nodup (cursor)
  (:documentation 
   "Move to the next non-duplicate element (with different
key.)  Returns has-tuple / secondary key / value / primary
key."))


(defgeneric cursor-prev-dup (cursor)
  (:documentation 
   "Move to the previous duplicate element (with the same key.)
Returns has-pair key value."))

;; Default implementation.  Plan is to update both backends when BDB 4.6 comes out
(defmethod cursor-prev-dup ((cur cursor))
  (when (cursor-initialized-p cur)
    (multiple-value-bind (exists? skey-cur)
	(cursor-current cur)
      (declare (ignore exists?))
      (multiple-value-bind (exists? skey value)
	  (cursor-prev cur)
	(if (lisp-compare-equal skey-cur skey)
	    (values exists? skey value)
	    (setf (cursor-initialized-p cur) nil))))))

(defgeneric cursor-prev-nodup (cursor)
  (:documentation 
   "Move to the previous non-duplicate element (with
different key.)  Returns has-pair key value."))

(defgeneric cursor-pprev-dup (cursor)
  (:documentation 
   "Move to the previous duplicate element (with the same key.)
Returns has-tuple / secondary key / value / primary key."))

;; Default implementation.  Plan is to update both backends when BDB 4.6 comes out
(defmethod cursor-pprev-dup ((cur cursor))
  (when (cursor-initialized-p cur)
    (multiple-value-bind (exists? skey-cur)
	(cursor-current cur)
      (declare (ignore exists?))
      (multiple-value-bind (exists? skey value pkey)
	  (cursor-pprev cur)
	(if (lisp-compare-equal skey-cur skey)
	    (values exists? skey value pkey)
	    (setf (cursor-initialized-p cur) nil))))))

(defgeneric cursor-pprev-nodup (cursor)
  (:documentation 
   "Move to the previous non-duplicate element (with
different key.)  Returns has-tuple / secondary key / value /
primary key."))

(defmacro with-btree-cursor ((var bt) &body body)
  "Macro which opens a named cursor on a BTree (primary or
not), evaluates the forms, then closes the cursor."
  (declare (inline make-cursor))
  `(let (,var)
     (declare (dynamic-extent ,var))
     (without-interrupts
       (setf ,var (make-cursor ,bt)))
     (unwind-protect
	  (progn ,@body)
       (without-interrupts
         (cursor-close ,var)))))

(defmethod remove-kv-pair (key value (dbt dup-btree))
  "Too bad there isn't a direct way to do this, but with
   ordered duplicates this should be reasonably efficient"
  (let ((sc (get-con dbt)))
    (ensure-transaction (:store-controller sc)
      (with-btree-cursor (cur dbt)
	(multiple-value-bind (exists? k v)
	    (cursor-get-both cur key value)
	  (declare (ignore k v))
  	  (when exists? 
	    (cursor-delete cur)))))))

(defmethod drop-btree ((bt btree))
  (ensure-transaction (:store-controller (get-con bt))
    (with-btree-cursor (cur bt)
      (loop for (exists? key) = (multiple-value-list (cursor-first cur))
	 then (multiple-value-list (cursor-next cur))
	 while exists?
	 do (remove-kv key bt)))))

(defmethod drop-btree ((bt indexed-btree))
  (with-transaction (:store-controller (get-con bt))
    (map-indices (lambda (name index)
		   (declare (ignore index))
		   (remove-index bt name))
		 bt)
    (call-next-method)))

(defmethod drop-btree ((index btree-index))
  "Btree indices don't need to have values removed,
   this happens on the primary when remove-kv is called"
  nil)

;; =======================================
;;   Generic Mapping Functions
;; =======================================

;; Utilities

(defun lisp-compare<= (a b)
  "A comparison function that mirrors the ordering of the data stores for <=
   on all sortable types.  It does not provide ordering on non-sorted values
   other than by type class (i.e. not serialized lexical values)"
  (declare (optimize (speed 3) (safety 2) (debug 0)))
  (handler-case 
      (typecase a
	(number (<= a b))
	(character (<= (char-code a) (char-code b)))
	(string (string-not-greaterp a b))
	(symbol (string-not-greaterp (symbol-name a) (symbol-name b)))
	(pathname (string-not-greaterp (namestring a) (namestring b)))
	(persistent (<= (oid a) (oid b)))
	(cons (or (lisp-compare<= (car a) (car b))
		  (lisp-compare<= (cdr a) (cdr b))))
	(t nil))
    (error ()
      (type<= a b))))

(defun lisp-compare< (a b)
  "A comparison function that mirrors the ordering of the data stores for <
   on all sortable types.  It does not provide ordering on non-sorted values
   other than by type class (i.e. not serialized lexical values)"
  (declare (optimize (speed 3) (safety 2) (debug 0)))
  (handler-case 
      (typecase a
	(number (< a b))
	(character (< (char-code a) (char-code b)))
	(string (string-lessp a b))
	(symbol (string-lessp (symbol-name a) (symbol-name b)))
	(pathname (string-lessp (namestring a) (namestring b)))
	(persistent (< (oid a) (oid b)))
	(cons (if (lisp-compare-equal (car a) (car b))
		  (lisp-compare< (cdr a) (cdr b))
		  (lisp-compare< (car a) (car b))))
	(t nil))
    (error () 
      (type< a b))))

(defun lisp-compare-equal (a b)
  "A lisp compare equal in same spirit as lisp-compare<.  Case insensitive for strings."
  (handler-case
      (typecase a
	(persistent (eq (oid a) (oid b)))
	(t (equal a b)))
    (error ()
      (equal a b))))

(defun lisp-compare>= (a b)
  (not (lisp-compare< a b)))

(defvar *current-cursor* nil
  "This dynamic variable is referenced only when deleting elements
   using the following function.  This allows mapping functions to
   delete elements as they map.  This is safe as we don't revisit
   values during maps")

(defmacro with-current-cursor ((cur) &body body)
  `(let ((*current-cursor* ,cur))
     (declare (special *current-cursor*))
     ,@body))

(defun remove-current-kv ()
  (unless *current-cursor*
    (error "Cannot call remove-current-kv outside of a map-btree or map-index function argument"))
  (cursor-delete *current-cursor*))

;; The primary mapping function

(defgeneric map-btree (fn btree &rest args &key start end value from-end collect &allow-other-keys)
  (:documentation   "Map btree maps over a btree from the value start to the value of end.
   If values are not provided, then it maps over all values.  BTrees 
   do not have duplicates, but map-btree can also be used with indices
   in the case where you don't want access to the primary key so we 
   require a value argument as well for mapping duplicate value sets.
   The collect keyword will accumulate the results from
   each call of fn in a fresh list and return that list in the 
   same order the calls were made (first to last)."))

(defun validate-map-call (start end)
  (unless (or (null start) (null end) (lisp-compare<= start end))
    (error "map-index called with start = ~A and end = ~A. Start must be less than or equal to end according to elephant::lisp-compare<=."
	   start end)))

(defmacro with-map-collector ((fn collect-p) &body body)
  "Binds free var results to the collected results of function in
   symbol-argument fn based on boolean parameter collect-p,
   otherwise result is nil"
  (with-gensyms (collector k v)
    `(let ((results nil))
       (flet ((,collector (,k ,v)
		(push (funcall ,fn ,k ,v) results)))
	 (declare (dynamic-extent (function ,collector)))
	 (let ((,fn (if ,collect-p #',collector ,fn)))
	   ,@body)))))

(defmacro with-map-wrapper ((fn btree collect cur) &body body)
  "Binds variable sc to the store controller, overrieds fn with a collector
   if dynamic value of collect is true and binds variable named cur to
   the current cursor"
  `(let ((sc (get-con ,btree)))
     (with-map-collector (,fn ,collect)
       (ensure-transaction (:store-controller sc :degree-2 *map-using-degree2*)
	 (with-btree-cursor (,cur ,btree)
	   (with-current-cursor (,cur)
	     ,@body))))))

(defmacro with-cursor-values (expr &body body)
  "Binds exists?, skey, val and pkey from expression assuming
   expression returns a set of cursor operation values or nil"
  `(multiple-value-bind (exists? skey val pkey)
       (the (values boolean t t t) ,expr)
     (declare (ignorable exists? skey val pkey))
     ,@body))

(defmacro iterate-map-btree (&key start continue step)
  "In context with bound variables: cur, sc, value, start, end, fn
   Provide a start expression that returns index cursor values
   Provide a continue expression that uses the
     bound variables key, start, value or end to determine if 
     the iteration should continue
   Provide a step expression that returns index cursor values."
  `(labels ((continue-p (key)
	      (declare (ignorable key))
	      ,continue))
     (declare (dynamic-extent (function continue-p)))
     (handler-case 
	 (with-cursor-values ,start
	   (when (and exists? (continue-p skey))
	     (funcall fn skey val)
	     (loop  
		(handler-case
		    (with-cursor-values ,step
		      (if (and exists? (continue-p skey))
			  (funcall fn skey val)
			  (return (nreverse results))))
		  (elephant-deserialization-error (e)
		    (declare (ignore e))
		    (format t "Deserialization error in map: returning nil for element~%")
		    (return nil))))))
       (elephant-deserialization-error (e)
	 (declare (ignore e))
	 (format t "Deserialization error in map: returning nil for element~%")
	 nil))))


;; NOTE: the use of nil for the last element in a btree only works because the C comparison
;; function orders by type tag and nil is the highest valued type tag so nils are the last
;; possible element in a btree ordered by value.


(defmethod map-btree (fn (btree btree) &rest args &key start end (value nil value-set-p) 
		      from-end collect &allow-other-keys)
  (declare (ignorable args))
  (validate-map-call start end)
  (cond (value-set-p (map-btree-values fn btree value collect))
	(from-end (map-btree-from-end fn btree start end collect))
	(t (map-btree-from-start fn btree start end collect))))

(defun map-btree-values (fn btree value collect)
  (with-map-wrapper (fn btree collect cur)
    (iterate-map-btree 
     :start (cursor-set cur value)
     :continue (lisp-compare-equal key value)
     :step (cursor-next cur))))

(defun map-btree-from-start (fn btree start end collect)
  (with-map-wrapper (fn btree collect cur)
    (iterate-map-btree
     :start (if start
		(cursor-set-range cur start)
		(cursor-first cur))
     :continue (or (null end) (lisp-compare<= key end))
     :step (cursor-next cur))))

(defun map-btree-from-end (fn btree start end collect)
  (with-map-wrapper (fn btree collect cur)
    (iterate-map-btree
     :start (if end
		(with-cursor-values (cursor-set-range cur end)
		  (cond ((and exists? (lisp-compare-equal skey end))
			 (cursor-next-nodup cur)
			 (cursor-prev cur))
			(t (cursor-prev cur))))
		(cursor-last cur))
     :continue (or (null start) (lisp-compare>= key start))
     :step (cursor-prev cur))))


;; Special support for mapping indexes of a secondary btree

(defgeneric map-index (fn index &rest args &key start end value from-end collect &allow-other-keys)
  (:documentation "Map-index is like map-btree but for secondary indices, it
   takes a function of three arguments: key, value and primary
   key.  As with map-btree the keyword arguments start and end
   determine the starting element and ending element, inclusive.
   Also, start = nil implies the first element, end = nil implies
   the last element in the index.  If you want to traverse only a
   set of identical key values, for example all nil values, then
   use the value keyword which will override any values of start
   and end.  The collect keyword will accumulate the results from
   each call of fn in a fresh list and return that list in the 
   same order the calls were made (first to last)"))

(defmacro with-map-index-collector ((fn collect-p) &body body)
  "Binds free var results to the collected results of function in
   symbol-argument fn based on boolean parameter collect-p,
   otherwise result is nil"
  (with-gensyms (collector k v pk)
    `(let ((results nil))
       (flet ((,collector (,k ,v ,pk)
		(push (funcall ,fn ,k ,v ,pk) results)))
	 (declare (dynamic-extent (function ,collector)))
	 (let ((,fn (if ,collect-p #',collector ,fn)))
	   ,@body)))))

(defmacro iterate-map-index (&key start continue step)
  "In context with bound variables: cur, sc, value, start, end, fn
   Provide a start expression that returns index cursor values
   Provide a continue expression that uses the
     bound variables key, start, value or end to determine if 
     the iteration should continue
   Provide a step expression that returns index cursor values."
  `(labels ((continue-p (key)
	      (declare (ignorable key))
	      ,continue))
     (declare (dynamic-extent (function continue-p)))
     (with-cursor-values ,start
       (when (and exists? (continue-p skey))
	 (funcall fn skey val pkey)
	 (loop  
	    (with-cursor-values ,step
	      (if (and exists? (continue-p skey))
		  (funcall fn skey val pkey)
		  (return (nreverse results)))))))))

(defmacro with-map-index-wrapper ((fn btree collect cur) &body body)
  "Binds variable sc to the store controller, overrieds fn with a collector
   if dynamic value of collect is true and binds variable named cur to
   the current cursor"
  `(let ((sc (get-con ,btree)))
     (with-map-index-collector (,fn ,collect)
       (ensure-transaction (:store-controller sc :degree-2 *map-using-degree2*)
	 (with-btree-cursor (,cur ,btree)
	   (with-current-cursor (,cur)
	     ,@body))))))

(defun pset-range-for-descending (cur end)
  (if (cursor-pset cur end)
      (progn
	(cursor-next-nodup cur)
	(cursor-pprev cur))
      (progn
	(cursor-pset-range cur end)
	(cursor-pprev cur))))

(defmethod map-index (fn (index btree-index) &rest args
		      &key start end (value nil value-set-p) from-end collect 
		      &allow-other-keys)
  (declare (ignore args))
  (validate-map-call start end)
  (cond (value-set-p (map-index-values fn index value collect))
	(from-end (map-index-from-end fn index start end collect))
	(t (map-index-from-start fn index start end collect))))

(defun map-index-values (fn index value collect)
  (with-map-index-wrapper (fn index collect cur)
    (iterate-map-index
     :start (cursor-pset cur value)
     :continue t
     :step (cursor-pnext-dup cur))))

(defun map-index-from-start (fn index start end collect)
  (with-map-index-wrapper (fn index collect cur)
    (iterate-map-index
      :start (if start 
		 (cursor-pset-range cur start) 
		 (cursor-pfirst cur))
      :continue (or (null end) (lisp-compare<= key end))
      :step (cursor-pnext cur))))

(defun map-index-from-end (fn index start end collect)
  (with-map-index-wrapper (fn index collect cur)
    (iterate-map-index
     :start (if end 
		(pset-range-for-descending cur end) 
		(cursor-plast cur))
     :continue (or (null start) (lisp-compare>= key start))
     :step (cursor-pprev cur))))

;; ===============================
;; Some generic utility functions
;; ===============================

(defmethod empty-btree-p ((btree btree))
  (ensure-transaction (:store-controller (get-con btree))
    (with-btree-cursor (cur btree)
      (multiple-value-bind (valid k) (cursor-next cur)
	(cond ((not valid) ;; truly empty
	       t)
	      ((and (eq btree (controller-root (get-con btree)))
		    (eq k *elephant-properties-label*)) ;; has properties
	       (not (cursor-next cur)))
	      (t nil))))))

(defun print-btree-entry (k v) 
  (format t "key: ~A / value: ~A~%" k v))

(defun dump-btree (bt &key (print-fn #'print-btree-entry) (count nil))
  "Print the contents of a btree for easy inspection & debugging"
  (format t "DUMP ~A~%" bt)
  (let ((i 0))
  (map-btree 
   (lambda (k v)
     (when (and count (>= (incf i) count))
       (return-from dump-btree))
     (funcall print-fn k v))
   bt)))

(defun print-btree-key-and-type (k v)
  (format t "key ~A / value type ~A~%" k (type-of v)))

(defun btree-keys (bt &key (print-fn #'print-btree-key-and-type) (count nil))
  (format t "BTREE keys and types for ~A~%" bt)
  (dump-btree bt :print-fn print-fn :count count))

(defun print-index-entry (k v pk)
  (format t "key: ~A / value: ~A / primary-key: ~A~%" k v pk))

(defun dump-index (idx &key (print-fn #'print-index-entry) (count nil))
  (format t "DMP INDEX ~A~%" idx)
  (let ((i 0))
  (map-index
   (lambda (k v pk)
     (when (and count (>= (incf i) count))
       (return-from dump-index))
     (funcall print-fn k v pk))
   idx)))

(defmethod btree-differ-p ((x btree) (y btree))
;;  (assert (eq (get-con x) (get-con y)))
  (ensure-transaction (:store-controller (get-con x))
    (ensure-transaction (:store-controller (get-con y))
      (let ((cx1 (make-cursor x)) 
	    (cy1 (make-cursor y))
	    (done nil)
	    (rv nil)
	    (mx nil)
	    (kx nil)
	    (vx nil)
	    (my nil)
	    (ky nil)
	    (vy nil))
	(cursor-first cx1)
	(cursor-first cy1)
	(do ((i 0 (1+ i)))
	    (done nil)
	  (multiple-value-bind (m k v) (cursor-current cx1)
	    (setf mx m)
	    (setf kx k)
	    (setf vx v))
	  (multiple-value-bind (m k v) (cursor-current cy1)
	    (setf my m)
	    (setf ky k)
	    (setf vy v))
	  (if (not (and (equal mx my)
			(equal kx ky)
			(equal vx vy)))
	      (setf rv (list mx my kx ky vx vy)))
	  (setf done (and (not mx) (not mx)))
	  (cursor-next cx1)
	  (cursor-next cy1)
	  )
	(cursor-close cx1)
	(cursor-close cy1)
	rv
	))))
