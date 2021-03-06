;;;
;;; Copyright (c) 2007-2011 Keith James. All rights reserved.
;;;
;;; This file is part of cl-genomic.
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;;

(in-package :bio-sequence)

(declaim (type fixnum *fasta-line-width*))
(defparameter *fasta-line-width* 50
  "Line width for printing Fasta files.")

(defparameter *token-cache-extend* 256
  "The number of elements by which the token cache is extended when it
becomes full of chunks of sequence tokens.")

(defmethod make-seq-input ((stream line-input-stream)
                           (format (eql :fasta))
                           &key (alphabet :dna) parser virtual)
  (let ((parser (or parser
                    (cond (virtual
                           (make-instance 'virtual-sequence-parser))
                          (t
                           (make-instance 'simple-sequence-parser))))))
      (defgenerator
          (more (has-sequence-p stream format))
          (next (read-fasta-sequence stream alphabet parser)))))

(defmethod make-seq-output ((stream stream) (format (eql :fasta))
                            &key token-case)
  (lambda (obj)
    (write-fasta-sequence obj stream :token-case token-case)))

(defmethod split-sequence-file (filespec (format (eql :fasta))
                                pathname-gen &key (chunk-size 1))
  (with-seq-input (seqi (pathname filespec) :fasta
                        :parser (make-instance 'raw-sequence-parser))
    (split-from-generator seqi #'write-fasta-sequence chunk-size pathname-gen)))

(defmethod has-sequence-p ((stream line-input-stream)
                           (format (eql :fasta)) &key alphabet)
  (declare (ignore alphabet))
  (let ((seq-header (find-line stream #'content-string-p)))
    (cond ((eql :eof seq-header)
           nil)
          (t
           (unwind-protect
                (check-record (fasta-header-p seq-header) nil
                              "the stream contains non-Fasta data ~s"
                              seq-header)
             (push-line stream seq-header))))))

(defmethod read-fasta-sequence ((stream line-input-stream)
                                (alphabet symbol)
                                (parser bio-sequence-parser))
  (restart-case
      (let ((seq-header (find-line stream #'content-string-p)))
        (cond ((eql :eof seq-header)
               (values nil nil))
              (t
               (check-field (fasta-header-p seq-header) nil seq-header
                            "~s is not recognised as as Fasta header"
                            seq-header)
               (multiple-value-bind (identity description)
                   (parse-fasta-header seq-header)
                 (begin-object parser)
                 (object-alphabet parser alphabet)
                 (object-identity parser identity)
                 (object-description parser description)
                 (loop
                    for line = (stream-read-line stream)
                    while (not (eql :eof line))
                    until (fasta-header-p line)
                    do (object-residues parser line)
                    finally (unless (eql :eof line) ; push back the new header
                              (push-line stream line)))
                 (values (end-object parser) t)))))
    (skip-sequence-record ()
      :report "Skip this sequence."
      ;; Restart skips on to the next header
      (let ((line (find-line stream #'fasta-header-p)))
        (unless (eql :eof line)
          (push-line stream line)))
      (values nil t))))

(defmethod write-fasta-sequence ((seq bio-sequence) stream &key token-case) 
  (declare (optimize (speed 3) (safety 0)))
  (let ((*print-pretty* nil)
        (len (length-of seq)))
    (declare (type fixnum len))
    (write-char #\> stream)
    (write-line (if (anonymousp seq)
                    ""
                  (identity-of seq)) stream)
    (loop
       for i of-type fixnum from 0 below len by *fasta-line-width*
       do (write-line
           (nadjust-case
            (coerce-sequence seq 'string
                             :start i
                             :end (min len (+ i *fasta-line-width*)))
            token-case) stream))))

(defmethod write-fasta-sequence ((alist list) stream &key token-case)
  (declare (optimize (speed 3) (safety 1)))
  (let ((*print-pretty* nil)
        (residues (let ((str (or (assocdr :residues alist) "")))
                    (nadjust-case str token-case)))
        (identity (or (assocdr :identity alist) "")))
    (declare (type simple-string residues))
    (write-char #\> stream)
    (write-line identity stream)
    (let ((len (length residues)))
      (loop
         for i from 0 below len by *fasta-line-width*
         do (write-line residues stream
                        :start i
                        :end (min len (+ i *fasta-line-width*)))))))

(defmethod write-fasta-sequence (obj filespec &key token-case)
  (with-open-file (stream filespec :direction :output :if-exists :supersede)
    (write-fasta-sequence obj stream :token-case token-case)))

(defun parse-fasta-header (str)
  "Performs a basic parse of a Fasta header string STR by removing the
leading '>' character and splitting the line on the first space(s)
into identity and description. This function supports pathological
cases where the identity, description, or both are empty strings."
  (let* ((split-index (position #\Space str :test #'char=))
         (identity  (string-left-trim '(#\>) (if split-index
                                                 (subseq str 0 split-index)
                                               str)))
         (description (if split-index
                          (string-trim '(#\Space) (subseq str split-index))
                        "")))
    (values identity description)))

(declaim (inline fasta-header-p))
(defun fasta-header-p (str)
  "Returns T if STR is a Fasta header (starts with the character
'>'), or NIL otherwise."
  (starts-with-char-p str #\>))
