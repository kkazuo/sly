;;;;; -*- indent-tabs-mode: nil -*-
;;;
;;; swank-mezzano.lisp --- SLIME backend for Mezzano
;;;
;;; This code has been placed in the Public Domain.  All warranties are
;;; disclaimed.
;;;

;;; Administrivia

(defpackage swank/mezzano
  (:use cl swank/backend))

(in-package swank/mezzano)

(defclass logical-pathname () ())

;;; swank-mop

(import-swank-mop-symbols :sys.clos '(:class-default-initargs
                                      :class-direct-default-initargs
                                      :class-finalized-p
                                      :class-prototype
                                      :specializer-direct-methods
                                      :generic-function-argument-precedence-order
                                      :generic-function-declarations
                                      :generic-function-method-combination
                                      :slot-definition-documentation
                                      :slot-definition-type))

(defun swank-mop:class-finalized-p (class)
  (declare (ignore class))
  t)

(defun swank-mop:class-prototype (class)
  (allocate-instance (if (symbolp class)
                         (find-class class)
                         class)))

(defun swank-mop:specializer-direct-methods (obj)
  (declare (ignore obj))
  '())

(defun swank-mop:generic-function-argument-precedence-order (gf)
  (sys.clos:generic-function-lambda-list gf))

(defun swank-mop:generic-function-declarations (gf)
  (declare (ignore gf))
  '())

(defun swank-mop:generic-function-method-combination (gf)
  (declare (ignore gf))
  :standard)

(defun swank-mop:slot-definition-documentation (slot)
  (declare (ignore slot))
  nil)

(defun swank-mop:slot-definition-type (slot)
  (declare (ignore slot))
  t)

(defimplementation gray-package-name ()
  "SYS.GRAY")

;;;; TCP server

(defclass listen-socket ()
  ((%host :initarg :host)
   (%port :initarg :port)
   (%connection-fifo :initarg :connections)
   (%callback :initarg :callback)))

(defimplementation create-socket (host port &key backlog)
  (let* ((connections (mezzano.supervisor:make-fifo (or backlog 10)))
         (sock (make-instance 'listen-socket
                              :host host
                              :port port
                              :connections connections
                              :callback (lambda (conn)
                                          (when (not (mezzano.supervisor:fifo-push
                                                      (make-instance 'mezzano.network.tcp::tcp-stream :connection conn)
                                                      connections
                                                      nil))
                                            ;; Drop connections when they can't be handled.
                                            (close conn)))))
         (listen-fn (slot-value sock '%callback)))
    (when (find port mezzano.network.tcp::*server-alist*
                :key #'first)
      (error "Server already listening on port ~D" port))
    (push (list port listen-fn) mezzano.network.tcp::*server-alist*)
    sock))

(defimplementation local-port (socket)
  (slot-value socket '%port))

(defimplementation close-socket (socket)
  (setf mezzano.network.tcp::*server-alist*
        (remove (slot-value socket '%callback)
                mezzano.network.tcp::*server-alist*
                :key #'second))
  (let ((fifo (slot-value socket '%connection-fifo)))
    (loop
       (let ((conn (mezzano.supervisor:fifo-pop fifo nil)))
         (when (not conn)
           (return))
         (close conn))))
  (setf (slot-value socket '%connection-fifo) nil))

(defimplementation accept-connection (socket &key external-format
                                             buffering timeout)
  (declare (ignore external-format buffering timeout))
  (mezzano.supervisor:fifo-pop
               (slot-value socket '%connection-fifo)))

(defimplementation preferred-communication-style ()
  :spawn)

;;;; Unix signals
;;;; ????

(defimplementation getpid ()
  0)

;;;; Compilation

(defun signal-compiler-condition (condition severity)
  (signal 'compiler-condition
          :original-condition condition
          :severity severity
          :message (format nil "~A" condition)
          :location nil))

(defimplementation call-with-compilation-hooks (func)
  (handler-bind
      ((sys.int::error
        (lambda (c)
          (signal-compiler-condition c :error)))
       (warning
        (lambda (c)
          (signal-compiler-condition c :warning)))
       (sys.int::style-warning
        (lambda (c)
          (signal-compiler-condition c :style-warning))))
    (funcall func)))

(defimplementation swank-compile-string (string &key buffer position filename
                                                policy)
  (declare (ignore buffer position filename policy))
  (with-compilation-hooks ()
    (eval (read-from-string (concatenate 'string "(progn " string " )"))))
  t)

(defimplementation swank-compile-file (input-file output-file load-p
                                                  external-format
                                                  &key policy)
  (with-compilation-hooks ()
    (multiple-value-prog1
        (compile-file input-file
                      :output-file output-file
                      :external-format external-format)
      (when load-p
        (load output-file)))))

(defimplementation find-external-format (coding-system)
  (if (or (equal coding-system "utf-8")
          (equal coding-system "utf-8-unix"))
      :default
      nil))

;;;; Debugging

;; Definitely don't allow this.
(defimplementation install-debugger-globally (function)
  (declare (ignore function))
  nil)

(defvar *current-backtrace*)

(defimplementation call-with-debugging-environment (debugger-loop-fn)
  (let ((*current-backtrace* '()))
    (let ((prev-fp nil))
      (sys.int::map-backtrace
       (lambda (i fp)
         (push (list (1- i) fp prev-fp) *current-backtrace*)
         (setf prev-fp fp))))
    (setf *current-backtrace* (reverse *current-backtrace*))
    (funcall debugger-loop-fn)))

(defimplementation compute-backtrace (start end)
  (subseq *current-backtrace* start end))

(defimplementation print-frame (frame stream)
  (format stream "~S" (sys.int::function-from-frame frame)))

(defimplementation frame-source-location (frame-number)
  (let* ((frame (nth frame-number *current-backtrace*))
         (fn (sys.int::function-from-frame frame)))
    (function-location fn)))

(defimplementation frame-locals (frame-number)
  (let* ((frame (nth frame-number *current-backtrace*))
         (fn (sys.int::function-from-frame frame))
         (info (sys.int::function-debug-info fn))
         (result '())
         (var-id 0))
    (loop
       for (name stack-slot) in (sys.int::debug-info-local-variable-locations info)
       do
         (push (list :name name
                     :id var-id
                     :value (sys.int::read-frame-slot frame stack-slot))
               result)
         (incf var-id))
    (multiple-value-bind (env-slot env-layout)
        (sys.int::debug-info-closure-layout info)
      (when env-slot
        (let ((env-object (sys.int::read-frame-slot frame env-slot)))
          (dolist (level env-layout)
            (loop
               for i from 1
               for name in level
               when name do
                 (push (list :name name
                             :id var-id
                             :value (svref env-object i))
                       result)
                 (incf var-id))
            (setf env-object (svref env-object 0))))))
    (reverse result)))

(defimplementation frame-var-value (frame-number var-id)
  (let* ((frame (nth frame-number *current-backtrace*))
         (fn (sys.int::function-from-frame frame))
         (info (sys.int::function-debug-info fn))
         (current-var-id 0))
    (loop
       for (name stack-slot) in (sys.int::debug-info-local-variable-locations info)
       do
         (when (eql current-var-id var-id)
           (return-from frame-var-value
             (sys.int::read-frame-slot frame stack-slot)))
         (incf current-var-id))
    (multiple-value-bind (env-slot env-layout)
        (sys.int::debug-info-closure-layout info)
      (when env-slot
        (let ((env-object (sys.int::read-frame-slot frame env-slot)))
          (dolist (level env-layout)
            (loop
               for i from 1
               for name in level
               when name do
                 (when (eql current-var-id var-id)
                   (return-from frame-var-value
                     (svref env-object i)))
                 (incf current-var-id))
            (setf env-object (svref env-object 0))))))
    (error "Invalid variable id ~D for frame number ~D." var-id frame-number)))

;;;; Definition finding

(defun top-level-form-position (pathname tlf)
  (ignore-errors
    (with-open-file (s pathname)
      (loop
         repeat tlf
         do (with-standard-io-syntax
              (let ((*read-suppress* t)
                    (*read-eval* nil))
                (read s nil))))
      (make-location `(:file ,(namestring s))
                     `(:position ,(1+ (file-position s)))))))

(defun function-location (function)
  "Return a location object for FUNCTION."
  (let* ((info (sys.int::function-debug-info function))
         (pathname (sys.int::debug-info-source-pathname info))
         (tlf (sys.int::debug-info-source-top-level-form-number info)))
    (top-level-form-position pathname tlf)))

(defimplementation find-definitions (name)
  (let ((result '()))
    (labels ((frob-fn (dspec fn)
               (let ((loc (function-location fn)))
                 (when loc
                   (push (list dspec loc) result))))
             (try-fn (name)
               (when (valid-function-name-p name)
                 (when (and (fboundp name)
                            (not (and (symbolp name)
                                      (or (special-operator-p name)
                                          (macro-function name)))))
                   (let ((fn (fdefinition name)))
                     (cond ((typep fn 'sys.clos:standard-generic-function)
                            (dolist (m (sys.clos:generic-function-methods fn))
                              (frob-fn `(defmethod ,name
                                            ,@(sys.clos:method-qualifiers m)
                                          ,(mapcar #'sys.clos:class-name
                                                   (sys.clos:method-specializers m)))
                                       (sys.clos:method-function m))))
                           (t
                            (frob-fn `(defun ,name) fn)))))
                 (when (compiler-macro-function name)
                   (frob-fn `(define-compiler-macro ,name)
                            (compiler-macro-function name))))))
      (try-fn name)
      (try-fn `(setf name))
      (try-fn `(sys.int::cas name))
      (when (and (symbolp name)
                 (get name 'sys.int::setf-expander))
        (frob-fn `(define-setf-expander ,name)
                 (get name 'sys.int::setf-expander)))
      (when (and (symbolp name)
                 (macro-function name))
        (frob-fn `(defmacro ,name)
                 (macro-function name))))
    result))

;;;; XREF
;;; Simpler variants.

(defun find-all-frefs ()
  (let ((frefs (make-array 500 :adjustable t :fill-pointer 0))
        (keep-going t))
    (loop
       (when (not keep-going)
         (return))
       (adjust-array frefs (* (array-dimension frefs 0) 2))
       (setf keep-going nil
             (fill-pointer frefs) 0)
       ;; Walk the wired area looking for FREFs.
       (sys.int::walk-area
        :wired
        (lambda (object address size)
          (when (sys.int::function-reference-p object)
            (when (not (vector-push object frefs))
              (setf keep-going t))))))
    (remove-duplicates (coerce frefs 'list))))

(defimplementation list-callers (function-name)
  (let ((fref-for-fn (sys.int::function-reference function-name))
        (callers '()))
    (loop
       for fref in (find-all-frefs)
       for fn = (sys.int::function-reference-function fref)
       for name = (sys.int::function-reference-name fref)
       when fn
       do
         (cond ((typep fn 'standard-generic-function)
                (dolist (m (sys.clos:generic-function-methods fn))
                  (when (member fref-for-fn
                                (get-all-frefs-in-function (sys.clos:method-function m)))
                    (push `((defmethod ,name
                                ,@(sys.clos:method-qualifiers m)
                              ,(mapcar (lambda (specializer)
                                         (if (typep specializer 'standard-class)
                                             (sys.clos:class-name specializer)
                                             specializer))
                                       (sys.clos:method-specializers m)))
                            ,(function-location (sys.clos:method-function m)))
                          callers))))
               ((member fref-for-fn
                        (get-all-frefs-in-function fn))
                (push `((defun ,name) ,(function-location fn)) callers))))
    callers))

(defun get-all-frefs-in-function (function)
  (loop
     for i below (sys.int::function-pool-size function)
     for entry = (sys.int::function-pool-object function i)
     when (sys.int::function-reference-p entry)
     collect entry
     when (compiled-function-p entry) ; closures
     append (get-all-frefs-in-function entry)))

(defimplementation list-callees (function-name)
  (let* ((fn (fdefinition function-name))
         ;; Grovel around in the function's constant pool looking for function-references.
         ;; These may be for #', but they're probably going to be for normal calls.
         ;; TODO: This doesn't work well on interpreted functions or funcallable instances.
         (callees (remove-duplicates (get-all-frefs-in-function fn))))
    (loop
       for fref in callees
       for name = (sys.int::function-reference-name fref)
       for fn = (sys.int::function-reference-function fref)
       when fn
       collect `((defun ,name) ,(function-location fn)))))

;;;; Documentation

(defimplementation arglist (name)
  (let ((macro (when (symbolp name)
                 (macro-function name)))
        (fn (if (functionp name)
                name
                (ignore-errors (fdefinition name)))))
    (cond
      (macro
       (get name 'sys.int::macro-lambda-list))
      (fn
       (cond
         ((typep fn 'sys.clos:standard-generic-function)
          (sys.clos:generic-function-lambda-list fn))
         (t
          (sys.int::debug-info-lambda-list (sys.int::function-debug-info fn)))))
      (t :not-available))))

(defimplementation type-specifier-p (symbol)
  (cond
    ((or (get symbol 'sys.int::type-expander)
         (get symbol 'sys.int::compound-type)
         (get symbol 'sys.int::type-symbol))
     t)
    (t :not-available)))

(defimplementation function-name (function)
  (sys.int::function-name function))

(defimplementation valid-function-name-p (form)
  "Is FORM syntactically valid to name a function?
   If true, FBOUNDP should not signal a type-error for FORM."
  (flet ((length=2 (list)
           (and (not (null (cdr list))) (null (cddr list)))))
    (or (symbolp form)
        (and (consp form) (length=2 form)
             (or (eq (first form) 'setf)
                 (eq (first form) 'sys.int::cas))
             (symbolp (second form))))))

(defimplementation describe-symbol-for-emacs (symbol)
  (let ((result '()))
    (when (boundp symbol)
      (setf (getf result :variable) nil))
    (when (and (fboundp symbol)
               (not (macro-function symbol)))
      (setf (getf result :function) (sys.int::debug-info-docstring (sys.int::function-debug-info (fdefinition symbol)))))
    (when (fboundp `(setf ,symbol))
      (setf (getf result :setf) (sys.int::debug-info-docstring (sys.int::function-debug-info (fdefinition `(setf ,symbol))))))
    (when (get symbol 'sys.int::setf-expander)
      (setf (getf result :setf) nil))
    (when (special-operator-p symbol)
      (setf (getf result :special-operator) nil))
    (when (macro-function symbol)
      (setf (getf result :macro) nil))
    (when (compiler-macro-function symbol)
      (setf (getf result :compiler-macro) nil))
    (when (type-specifier-p symbol)
      (setf (getf result :type) nil))
    (when (find-class symbol nil)
      (setf (getf result :class) nil))
    result))

;;;; Multithreading

;; FIXME: This should be a weak table.
(defvar *thread-ids-for-emacs* (make-hash-table))
(defvar *next-thread-id-for-emacs* 0)
(defvar *thread-id-for-emacs-lock* (mezzano.supervisor:make-mutex
                                    "SWANK thread ID table"))

(defimplementation spawn (fn &key name)
  (mezzano.supervisor:make-thread fn :name name))

(defimplementation thread-id (thread)
  (mezzano.supervisor:with-mutex (*thread-id-for-emacs-lock*)
    (let ((id (gethash thread *thread-ids-for-emacs*)))
      (when (null id)
        (setf id (incf *next-thread-id-for-emacs*)
              (gethash thread *thread-ids-for-emacs*) id
              (gethash id *thread-ids-for-emacs*) thread))
      id)))

(defimplementation find-thread (id)
  (mezzano.supervisor:with-mutex (*thread-id-for-emacs-lock*)
    (gethash id *thread-ids-for-emacs*)))

(defimplementation thread-name (thread)
  (mezzano.supervisor:thread-name thread))

(defimplementation thread-status (thread)
  (format nil "~:(~A~)" (mezzano.supervisor:thread-state thread)))

(defimplementation current-thread ()
  (mezzano.supervisor:current-thread))

(defimplementation all-threads ()
  (mezzano.supervisor:all-threads))

(defimplementation thread-alive-p (thread)
  (not (eql (mezzano.supervisor:thread-state thread) :dead)))

(defimplementation interrupt-thread (thread fn)
  (mezzano.supervisor:establish-thread-foothold thread fn))

(defimplementation kill-thread (thread)
  ;; Documentation says not to execute unwind-protected sections, but there's no
  ;; way to do that.
  ;; And killing threads at arbitrary points without unwinding them is a good
  ;; way to hose the system.
  (mezzano.supervisor:terminate-thread thread))

(defvar *mailbox-lock* (mezzano.supervisor:make-mutex "mailbox lock"))
(defvar *mailboxes* (make-hash-table)) ; should also be weak.

(defstruct (mailbox (:conc-name mailbox.))
  thread
  (mutex (mezzano.supervisor:make-mutex))
  (queue '() :type list))

(defun mailbox (thread)
  "Return THREAD's mailbox."
  (mezzano.supervisor:with-mutex (*mailbox-lock*)
    (let ((mbox (gethash thread *mailboxes*)))
      (when (not mbox)
        (setf mbox (make-mailbox :thread thread)
              (gethash thread *mailboxes*) mbox))
      mbox)))

(defimplementation send (thread message)
  (let* ((mbox (mailbox thread))
         (mutex (mailbox.mutex mbox)))
    (mezzano.supervisor:with-mutex (mutex)
      (setf (mailbox.queue mbox)
            (nconc (mailbox.queue mbox) (list message))))))

(defimplementation receive-if (test &optional timeout)
  (let* ((mbox (mailbox (current-thread)))
         (mutex (mailbox.mutex mbox)))
    (assert (or (not timeout) (eq timeout t)))
    (loop
       (check-slime-interrupts)
       (mezzano.supervisor:with-mutex (mutex)
         (let* ((q (mailbox.queue mbox))
                (tail (member-if test q)))
           (when tail
             (setf (mailbox.queue mbox) (nconc (ldiff q tail) (cdr tail)))
             (return (car tail))))
         (when (eq timeout t) (return (values nil t))))
       (sleep 0.2))))

(defvar *registered-threads* (make-hash-table))
(defvar *registered-threads-lock* (mezzano.supervisor:make-mutex "registered threads lock"))

(defimplementation register-thread (name thread)
  (declare (type symbol name))
  (mezzano.supervisor:with-mutex (*registered-threads-lock*)
    (etypecase thread
      (null
       (remhash name *registered-threads*))
      (mezzano.supervisor:thread
       (setf (gethash name *registered-threads*) thread))))
  nil)

(defimplementation find-registered (name)
  (mezzano.supervisor:with-mutex (*registered-threads-lock*)
    (values (gethash name *registered-threads*))))

(defimplementation wait-for-input (streams &optional timeout)
  (loop
       (let ((ready '()))
         (dolist (s streams)
           (when (or (listen s)
                     (and (typep s 'mezzano.network.tcp::tcp-stream)
                          (mezzano.network.tcp::tcp-connection-closed-p s)))
             (push s ready)))
         (when ready
           (return ready))
         (when (check-slime-interrupts)
           (return :interrupt))
         (when timeout
           (return '()))
         (sleep 1)
         (when (numberp timeout)
           (decf timeout 1)
           (when (not (plusp timeout))
             (return '()))))))

;;;;  Locks

(defimplementation make-lock (&key name)
  (mezzano.supervisor:make-mutex name))

(defimplementation call-with-lock-held (lock function)
  (mezzano.supervisor:with-mutex (lock)
    (funcall function)))

;;;; Character names

(defimplementation character-completion-set (prefix matchp)
  ;; TODO: Unicode characters too.
  (loop
     for names in sys.int::*char-name-alist*
     append
       (loop
          for name in (rest names)
          when (funcall matchp prefix name)
          collect name)))